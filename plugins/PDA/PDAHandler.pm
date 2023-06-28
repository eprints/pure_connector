package PDA::PDAHandler;

use EPrints;
use EPrints::XML;
use EPrints::Apache::AnApache;
use EPrints::Sword::Utils;
use EPrints::Plugin::Import;
use EPrints::Plugin::Import::DefaultXML;
use EPrints::Plugin::Import::XML;
EPrints::DataObj::User;

use IO::File;

use PDA::XMLImportManager;
use PDA::XMLUserIdAugmentingImportManager;
use PDA::PDAUtil;

use strict;

my @DOC_FIELDS = qw(formatdesc security license date_embargo content);
my @PRESERVE_FIELDS = qw();
my @CLEAR_FIELDS = qw();

sub handler {
	my $request = shift;

	my $session = new EPrints::Session(2);
	if ( !defined $session ) {
		print STDERR
		  "\n[PDA] [INTERNAL-ERROR] Could not create session object.";
		$request->status(500);
		return Apache2::Const::DONE;
	}

	# Pull in configuration for constant arrays
	@DOC_FIELDS = @{$session->config( 'pda', 'doc_fields' )} if defined $session->config( 'pda', 'doc_fields' );
	@PRESERVE_FIELDS = @{$session->config( 'pda', 'preserve_fields' )} if defined $session->config( 'pda', 'preserve_fields' );
	@CLEAR_FIELDS = @{$session->config( 'pda', 'clear_fields' )} if defined $session->config( 'pda', 'clear_fields' );


	# Authenticating user and behalf user
	my $response = EPrints::Sword::Utils::authenticate( $session, $request );

	# $response->{status_code} defined means there was an authentication error
	if ( defined $response->{error} ) {
		if ( defined $response->{error}->{x_error_code} ) {
			$request->headers_out->{'X-Error-Code'} = $response->{error}->{x_error_code};
		}

		if ( $response->{error}->{status_code} == 401 ) {
			$request->headers_out->{'WWW-Authenticate'} = 'Basic realm="PDA"';
		}

		$request->status( $response->{error}->{status_code} );

		$session->terminate;
		return Apache2::Const::DONE;
	}

	my $uri = $request->uri;
	if($uri =~ /^\/pda\/handler/)
	{
		$uri = substr($uri, 12)
	}
	
	my @uri_elements = split('/', $uri);
	
	my $user = $response->{owner};
		
	my $util = new PDA::PDAUtil($request, $session, $user->get_id(), @uri_elements);
	my $result = Apache2::Const::DONE;
	
	# GET    /                            - Gets repository information (XML document)
	# POST   /archive                     - Deposits an eprint into the given dataset
	# GET    /eprint/1                    - Retrieves an eprint
	# PUT    /eprint/1                    - Update an eprint
	# DELETE /eprint/1                    - Delete an eprint
	# POST   /eprint/1/documents/file.pdf - Adds a new document to the eprint
	# GET    /eprint/1/documents/1        - Reads a file from the eprint
	# PUT    /eprint/1/documents/1        - Updates file metadata
	# DELETE /eprint/1/documents/1        - Removes a document from the eprint

	if($uri =~ /^\/$/)                      { serve_identify($util);                  }
	elsif($uri =~ /^\/\w+$/)                { serve_dataset($util);                   }
	elsif($uri =~ /^\/\w+\/\d+$/)           { serve_eprint($util);                    }
	elsif($uri =~ /^\/\w+\/\d+\/documents/) { serve_documents($util);                 }
	else                    { $util->serve_response(404, "Unknown URI pattern $uri"); }
	
	$session->terminate;
	return $result;
}

# -------------------------------- Identify --------------------------------

sub serve_identify
{
	my($util) = @_;
	my $session = $util->{session};
	
	my $response_element = $session->make_element("identify");
	my $version_element  = $session->make_element("version");
	$version_element->appendChild($session->make_text("1.0.0"));
	$response_element->appendChild($version_element);

	$util->send_xml($response_element);
}

# -------------------------------- Dataset --------------------------------

sub serve_dataset
{
	my($util) = @_;
	my $session = $util->{session};

	# load dataset
	my $dataset = $util->get_dataset();
	return if not $dataset;
	
	# check that this is actually a put
	my $method = $ENV{REQUEST_METHOD};
	if(not $method eq 'PUT') {
		$util->serve_response(404, "Method $method not supported on dataset");
		return;
	}

	# intialize plugin
	my $xml_plugin = new PDA::XMLUserIdAugmentingImportManager('session'=>$session, 'owner'=>$util->get_owner());
	
	# stream data to tmp file
	my $tmp_file = "/tmp/pdahandler.$$.data";
	my $buffer = "";
	my $tmp_filehandle;
	open($tmp_filehandle, ">" . $tmp_file);
	while($util->{request}->read($buffer, 1024))
	{
		print $tmp_filehandle $buffer;
	}
	close($tmp_filehandle);
	
	# and translate XML to a data object
	open($tmp_filehandle, "<" . $tmp_file);
	my $publication_list = $xml_plugin->input_fh(
		dataset=>$dataset
		, fh=>$tmp_filehandle
	);
	close($tmp_filehandle);
	unlink($tmp_file);
	my $eprint_id = $publication_list->{ids}[0];
	my $eprint = $dataset->get_object($session, $eprint_id);
	$eprint->set_value('userid', $util->get_owner());
	$eprint->commit();

	# send success XML
	my $response_element = $session->make_element("response");
	my $ids_element  = $session->make_element("ids");
	my $id_element  = $session->make_element("id");
	$id_element->appendChild( $session->make_text($eprint_id) );
	$ids_element->appendChild($id_element);
	$response_element->appendChild($ids_element);
	
	$util->send_xml($response_element);
}

# -------------------------------- EPrint --------------------------------

sub serve_eprint
{
	my($util) = @_;
	my $session = $util->{session};

	# load dataset
	my $dataset = $util->get_dataset();
	return if not $dataset;
	
	# load eprint
	my $eprint = $util->get_eprint($dataset);
	return if not $eprint;

	# switch operation based on method
	my $method = $ENV{REQUEST_METHOD};
	if($method eq 'GET')       { serve_eprint_get($util, $eprint);       }
	elsif($method eq 'PUT')    { serve_eprint_put($util, $eprint);       }
	elsif($method eq 'DELETE') { serve_eprint_delete($util, $eprint);    }
	else                       { $util->serve_response(404, "Method $method not available on eprint"); }
}

sub serve_eprint_get
{
	my($util, $eprint) = @_;
	
	my $xml = $eprint->to_xml(
		'no_xmlns'=>0
		, 'embed'=>0
	);
	
	$util->send_xml($xml);
}

sub serve_eprint_put
{
	my($util, $eprint) = @_;
	my $eprint_id = $eprint->get_id();
	my $dataset = $eprint->get_dataset();

	my $debug = defined $util->{session}->config( 'pda', 'debug' ) ? $util->{session}->config( 'pda', 'debug' ) : 0;
	
	# intialize plugin
	my $xml_plugin = new EPrints::Plugin::Import::XML('session'=>$util->{session});
	
	# create fake import manager
	my $xml_import_manager = new PDA::XMLImportManager($util->{session}, $xml_plugin, $eprint);
	
	# create XML handler
	my $handler = {
		dataset => $dataset,
		state => 'toplevel',
		plugin => $xml_import_manager,
		depth => 0,
		tmpfiles => [],
		imported => [], };
	bless $handler, "EPrints::Plugin::Import::DefaultXML::Handler";

	# stream data to tmp file
	my $tmp_file = "/tmp/pdahandler.$eprint_id.$$.data";
	my $buffer = "";
	my $tmp_filehandle;
	open($tmp_filehandle, ">" . $tmp_file);
	while($util->{request}->read($buffer, 1024))
	{
		print $tmp_filehandle $buffer;
	}
	close($tmp_filehandle);

	# parse xml
	open($tmp_filehandle, "<" . $tmp_file);
	eval { EPrints::XML::event_parse( $tmp_filehandle, $handler ) };
	close($tmp_filehandle);
	unlink($tmp_file) unless $debug;
	if ($@ and $@ ne "\n") # die if parsing failed
	{
		$util->serve_response(500, $@);
		return;
	}
	my $epdata = $xml_import_manager->{epdata};
	
	# remove old values
	my $old_epdata = EPrints::Utils::clone( $eprint->{data} );
	foreach my $field ( @{$dataset->{fields}} )
	{
		if( ! grep {$_ eq $field->{name}} @CLEAR_FIELDS)
		{
			next if grep {$_ eq $field->{name}} @PRESERVE_FIELDS;
			next if grep {$_ eq $field} @{$dataset->{system_fields}};
			next if $field->is_virtual;
		}
		$field->set_value( $eprint, undef );
	}
	
	# and update eprint with new values
	foreach my $fieldname (keys %$epdata)
	{
		if( $dataset->has_field( $fieldname ) )
		{
			# Can't currently set_value on subobjects
			my $field = $dataset->get_field( $fieldname );
			next if $field->is_type( "subobject" );
			$eprint->set_value( $fieldname, $epdata->{$fieldname} );
		}
	}
	my $new_epdata = $eprint->{data};
	my $changed = 0;
	foreach my $fieldname (keys %$new_epdata)
	{
		my $fieldchanged = $util->compare_field_data( $old_epdata->{$fieldname}, $new_epdata->{$fieldname} );
		$changed = 1 if $fieldchanged;
		print STDERR "[PDA] eprintid $eprint_id has changed $fieldname field\n" if $fieldchanged and $debug;
	}

	if ( $changed )
	{
		my $success = $eprint->commit();
		if( !$success )
		{
			$util->serve_response(500, $success);
			return;
		}
		
		$util->serve_response(200, "ePrint with id $eprint_id is updated");
		return;
	}
	$util->serve_response(200, "ePrint with id $eprint_id did not require updating");
}

sub serve_eprint_delete
{
	my($util, $eprint) = @_;
	
	my $eprint_id = $eprint->get_id();

    my $status = $eprint->get_value("eprint_status");

    # If status is archive, don't delete, but move to deleted status (UKPURE-912)
    if ($status eq "archive") {
        $eprint->move_to_deletion();
        my $result = $eprint->commit();
        if ($result) {
            $util->serve_response(200, "ePrint with id $eprint_id is marked as deleted");
        } else {
            $util->serve_response(500, "Unable to mark ePrint with id $eprint_id as deleted");
        }
    }
    else {  # If status != archive, go on and remove the eprint
	    my $result = $eprint->remove();
    	if($result) {
	    	$util->serve_response(200, "ePrint with id $eprint_id is removed");
    	} else {
	    	$util->serve_response(500, "Unable to remove ePrint with id $eprint_id");
    	}
    }
}

# -------------------------------- Documents --------------------------------
sub serve_documents
{
	my($util) = @_;

	# load dataset
	my $dataset = $util->get_dataset();
	return if not $dataset;
	
	# load eprint
	my $eprint = $util->get_eprint($dataset);
	return if not $eprint;
	
	# switch operation based on method
	my $method = $ENV{REQUEST_METHOD};
	if($method eq 'GET')       { serve_documents_get($util, $eprint);    }
	elsif($method eq 'POST')   { serve_documents_post($util, $eprint);   }
	elsif($method eq 'PUT')    { serve_documents_put($util, $dataset, $eprint);   }
	elsif($method eq 'DELETE') { serve_documents_delete($util, $eprint); }
	else                       { $util->serve_response(404, "Method $method not available on document"); }
}

sub serve_documents_get
{
	my($util, $eprint) = @_;
	my $document_id = $util->{uri_elements}->[4];
	
	# Find document
	my $document = get_document($util, $eprint, $document_id);
	return if not $document;

	# Find filename
	my $filename = $util->{uri_elements}->[5]; # first from URI
	if($filename eq undef)
	{
		$filename = $document->get_main(); # Then from main file
	}
	my %files = $document->files(); 
	if($filename eq undef)
	{
		my @file_names = keys %files; # And finally we just take the first file
		if(scalar @file_names eq 0)
		{
			$util->serve_response(404, "No files associated with document");
			return;
		}
		$filename = $file_names[0];
	}

	# Create document path
	my $path = $document->local_path."/".$filename;
	
	# And send file
	$util->{request}->content_type($document->get_value("format"));
	$util->{request}->headers_out->{'Content-Length'} = $files{$filename}; 
	$util->{request}->sendfile($path);
}

sub serve_documents_post
{
	my($util, $eprint) = @_;
	my $session = $util->{session};
	my $repository = $util->{repository};
	my $request = $util->{request};
	my $filename = $util->{uri_elements}->[4];

	# Create base document data
	my $doc_data = { eprintid => $eprint->get_id };
	$doc_data->{format} = $repository->call( 'guess_doc_type', $session, $filename);
	
	# description
	if($util->get_request_param('description')) 
	{
		$doc_data->{formatdesc} = $util->get_request_param('description');
	}

	# embargo
	if($util->get_request_param('embargoDate')) 
	{
		$doc_data->{date_embargo} = $util->get_request_param('embargoDate');
	}

	# visibility
	if($util->get_request_param('visibility') and $util->get_request_param('visibility') ne 'public') 
	{
		$doc_data->{security} = $util->get_request_param('visibility');
	}

	# document version
	if($util->get_request_param('documentVersion')) 
	{
		$doc_data->{content} = $util->get_request_param('documentVersion');
	}
	
	# license
	if($util->get_request_param('license')) 
	{
		$doc_data->{license} = $util->get_request_param('license');
	}
	
	# Create document object
	my $doc_dataset = $repository->get_dataset('document');
	my $document = $doc_dataset->create_object( $util->{session}, $doc_data );
	if( !defined $document )
	{
		$util->serve_response(500, "Create document failed");
		return;
	}
	
	# Download file to a tmp file
	my $tmp_file = "/tmp/pdahandler.$$.data";
	my $buffer = "";
	my $tmp_filehandle;
	open($tmp_filehandle, ">" . $tmp_file);
	while($request->read($buffer, 1024))
	{
		print $tmp_filehandle $buffer;
	}
	close($tmp_filehandle);
	
	my $filesize = -s $tmp_file;
	my $preserve_path = 'false';
	
	# And stream it into the repository
    
	open($tmp_filehandle, "<" . $tmp_file);
	my $success = $document->upload($tmp_filehandle, $filename, $preserve_path, $filesize);
	if( !$success )
	{
		$document->remove();
		close($tmp_filehandle);
		unlink($tmp_file);
		$util->serve_response(500, "Upload failed");
		return;
	}
	close($tmp_filehandle);
	unlink($tmp_file);
	
	# send success XML
	my $response_element = $session->make_element("response");
	my $ids_element  = $session->make_element("ids");
	
	my $id_element  = $session->make_element("id");
	$id_element->appendChild( $session->make_text($document->get_value("docid")) );
	$ids_element->appendChild($id_element);
	$response_element->appendChild($ids_element);
	
	$util->send_xml($response_element);
}

sub serve_documents_put
{
	my($util, $dataset, $eprint) = @_;
	my $session = $util->{session};
	my $repository = $util->{repository};
	my $request = $util->{request};


	# Find document
	my $document_id = $util->{uri_elements}->[4];
	my $document = get_document($util, $eprint, $document_id);
	return if not $document;
	
	# Find filename
	my $filename = $util->{uri_elements}->[5]; # first from URI
	if($filename eq undef)
	{
		$filename = $document->get_main(); # Then from main file
	}
	my %files = $document->files(); 
	if($filename eq undef)
	{
		my @file_names = keys %files; # And finally we just take the first file
		if(scalar @file_names eq 0)
		{
			$util->serve_response(404, "No files associated with document");
			return;
		}
		$filename = $file_names[0];
	}

	# Parse posted XML
	my $doc = parse_posted_xml_to_dom($util, $eprint, $dataset);
	return if not $doc;

	# Extract fields from xml	
	my $root = $doc->documentElement;
	my $epdata = {};
	foreach my $element ( $root->getChildNodes )
	{
		next unless EPrints::XML::is_dom( $element, "Element" ); # we only want elements
		
		my $name = $element->nodeName;
		my $t = '';
		foreach my $cnode ( $element->getChildNodes )
		{
			if( EPrints::XML::is_dom( $cnode,"Text" ) )
			{
				$t.=$cnode->nodeValue;
			}
		}
		$epdata->{$name} = $t;
	}
	EPrints::XML::dispose($doc);
		
	
	# Update document
	foreach my $fieldname (@DOC_FIELDS)
	{
		$document->set_value($fieldname, $epdata->{$fieldname});
	}

	my $success = $document->commit();
	if( !$success )
	{
		$util->serve_response(500, $success);
		return;
	}
		
	$util->serve_response(200, "document with id $document_id is updated");
}

sub serve_documents_delete
{
	my($util, $eprint) = @_;
	my $document_id = $util->{uri_elements}->[4];
	
	# Find document
	my $document = get_document($util, $eprint, $document_id);
	return if not $document;
	
	# Check for filename (only delete that file)
	my $filename = $util->{uri_elements}->[5];
	if($filename)
	{
		my %files = $document->files();
		my $files_size = keys %files;
		if($files_size > 1) # if we got more than one file, we just remove the file and leave the document
		{
			my $success = $document->remove_file($filename);
			if($success) {
				$util->serve_response(200, "File with name $filename is removed");
			} else {
				$util->serve_response(500, "Unable to remove file with name $filename: " . $success);
			}
			return;
		}
	}
	
	# And remove it
	my $success = $document->remove();
	if($success) {
		$util->serve_response(200, "Document with id $document_id is removed");
	} else {
		$util->serve_response(500, "Unable to remove document with id $document_id");
	}
}

sub get_document
{
	my($util, $eprint, $document_id) = @_;
	
	# Loop through documents finding the right one
	foreach my $doc ( $eprint->get_all_documents )
	{
		return $doc if $doc->get_value("docid") eq $document_id;
	}
	
	# Did not find the right one
	$util->serve_response(404, "Unable to find document with id $document_id");
	return undef;
}

sub parse_posted_xml_to_dom 
{
	my($util, $eprint, $dataset) = @_;
	
	# stream data to tmp file
	my $tmp_file = "/tmp/pdahandler.$$.data";
	my $buffer = "";
	my $tmp_filehandle;
	open($tmp_filehandle, ">" . $tmp_file);
	while($util->{request}->read($buffer, 1024))
	{
		print $tmp_filehandle $buffer;
	}
	close($tmp_filehandle);
	
	# parse to dom
	my $doc;
	eval { $doc = EPrints::XML::parse_xml("$tmp_file"); };

	unlink($tmp_file);

	if( $@ )
	{
		$util->serve_response(500, $@);
		return;
	}
	
	return $doc;
}

1;

