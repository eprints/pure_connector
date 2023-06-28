package PDA::XMLUserIdAugmentingImportManager;

use strict;

use EPrints::Plugin::Import::XML;

our @ISA = qw/ EPrints::Plugin::Import::XML /;

sub new
{
	my( $class, %params) = @_;

	my $self = $class->SUPER::new(%params);
	$self->{owner} = $params{owner};

	return $self;
}

sub xml_to_epdata
{
	my( $self, $dataset, $xml ) = @_;
	
	my $epdata = $self->SUPER::xml_to_epdata( @_[1..$#_] );
	$epdata->{userid} = $self->{owner};
	
	return $epdata;
}
