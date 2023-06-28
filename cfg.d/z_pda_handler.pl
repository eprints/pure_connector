$c->{custom_handlers}->{pda}->{regex} = '^URLPATH/pda';
$c->{custom_handlers}->{pda}->{function} = sub
{
	my ( $r ) = @_;
 
	$r->handler( 'perl-script' );
  	$r->set_handlers( PerlResponseHandler => [ 'PDA::PDAHandler' ] );
  	return EPrints::Const::OK;
};

$c->{pda}->{doc_fields} = [ qw/ formatdesc security license date_embargo content / ];
$c->{pda}->{preserve_fields} = [];
$c->{pda}->{clear_fields} = [];
$c->{pda}->{debug} = 0;
