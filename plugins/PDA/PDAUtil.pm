package PDA::PDAUtil;

use strict;

use URI::Escape;

sub new
{
	my($class, $request, $session, $owner, @uri_elements) = @_;

	my $self = {};
	bless $self, $class;

	$self->{session} = $session;
	$self->{request} = $request;
	$self->{repository} = $session->get_repository;
	$self->{owner} = $owner;
	$self->{uri_elements} = \@uri_elements;

	return $self;
}

# -------------------------------- Utility Methods --------------------------------

sub get_dataset
{
	my($self) = @_;
	
	my $dataset_name = $self->{uri_elements}->[1];

	# load dataset
	my $dataset = $self->{repository}->get_dataset($dataset_name);
	if($dataset eq undef) {
		serve_response(404, "Unknown dataset " . $dataset_name);
	}
	
	return $dataset;
}

sub get_eprint
{
	my($self, $dataset) = @_;

	my $eprint_id = $self->{uri_elements}->[2];
	
	# load eprint
	my $eprint = $dataset->get_object($self->{session}, $eprint_id);
	if($eprint eq undef) {
		$self->serve_response(404, "Unkown eprint $eprint_id in dataset");
		return;
	}
	
	return $eprint;
}

sub serve_response
{
	my($self, $code, $msg) = @_;

	# response element
	my $response_element = $self->{session}->make_element("response");
	
	my $code_element  = $self->{session}->make_element("code");
	$code_element->appendChild($self->{session}->make_text($code));
	$response_element->appendChild($code_element);
	
	if($code ne 200) {
		my $element = $self->{session}->make_element("error");
		$element->appendChild($self->{session}->make_text($msg));
		$response_element->appendChild($element);
	} else {
		my $element = $self->{session}->make_element("message");
		$element->appendChild($self->{session}->make_text($msg));
		$response_element->appendChild($element);
	}
	

	$self->send_xml($response_element);
	
	$self->{request}->status($code);
}

sub send_xml
{
	my( $self, $xml ) = @_;
	
	my $content = '<?xml version="1.0" encoding=\'utf-8\'?>'. "\n" . $xml->toString();

	my $xmlsize = length $content;
	$self->{request}->content_type('application/xml');
	# unable to report content length because length does not return the correct number of bytes for UTF-8 data
	#$request->headers_out->{'Content-Length'} = $xmlsize; 

	# sending data...
	$self->{request}->puts($content);
}

sub get_owner
{
	my( $self ) = @_;
	
	return $self->{owner};
}

sub get_request_param
{
	my( $self, $param ) = @_;
	
	my $param_string = $self->{request}->args;
	return undef if not $param_string;

	# special case for + which is used instead of spaces	
	$param_string =~ s/\+/ /g;
	
	my @key_value_strings = split('&', $param_string);
	my %params = {};
	foreach my $key_value (@key_value_strings)
	{
		my ($key, $value) = split('=', $key_value);
		$params{$key} = uri_unescape($value);
	}
	
	return $params{$param};	
}

sub compare_field_data
{
	my ( $self, $value1, $value2 ) = @_;

	if ( ref( $value1 ) eq "ARRAY" || ref( $value2 ) eq "ARRAY" )
	{
		$value1 = [] unless defined $value1;
		$value2 = [] unless defined $value2;
		my $max = scalar @$value1;
		$max = scalar @$value2 if scalar @$value2 > scalar @$value1;
		foreach ( my $i = 0; $i < $max; $i++ )
		{
			return 1 if $self->compare_field_data( $value1->[$i], $value2->[$i] );
		}
		return 0;
	}
	elsif( ref( $value1 ) eq "HASH" || ref( $value2 ) eq "HASH" )
	{
		foreach ( keys %$value1 )
		{
			return 1 if $self->compare_field_data( $value1->{$_}, $value2->{$_} );
		}
		foreach ( keys %$value2 )
                {
			return 1 if $self->compare_field_data( $value2->{$_}, $value1->{$_} );
                }
		return 0;
	}
	$value1 = "" unless defined $value1;
        $value2 = "" unless defined $value2;
	$value1 =~ s/^\s+|\s+$//g;
	$value2 =~ s/^\s+|\s+$//g;
	return 0 if $value1 eq $value2;
	return 1;
}

1;
