package PDA::XMLImportManager;

use strict;

sub new
{
	my($class, $session, $plugin, $eprint) = @_;

	my $self = {};
	bless $self, $class;

	$self->{session} = $session;
	$self->{plugin} = $plugin;
	$self->{eprint} = $eprint;

	return $self;
}

sub xml_to_dataobj
{
        my($self, $dataset, $xml) = @_;

        # store epdata
        $self->{epdata} = $self->{plugin}->xml_to_epdata( $dataset, $xml );

        # fake it and return the original eprint, we wont create the real one until later
        return $self->{eprint};
}


sub epdata_to_dataobj
{
	my($self, $dataset, $epdata) = @_;
	
	# store epdata
	$self->{epdata} = $epdata;
	
	# fake it and return the original eprint, we wont create the real one until later
	return $self->{eprint};
}

sub top_level_tag
{
	my($self, $dataset) = @_;

	return $self->{plugin}->top_level_tag($dataset);
}

sub unknown_start_element
{
	my($self, $found, $expected) = @_;

	$self->{plugin}->unknown_start_element($found, $expected);
}

1;
