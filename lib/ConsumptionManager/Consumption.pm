package ConsumptionManager::Consumption;

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
    cm_consumptionUpdate
);

our $VERSION = '0.1.0';

=head1 NAME

ConsumptionManager::Consumption

=head1 DESCRIPTION

Consumption calculations.

=cut

###############################################################################
# Update consumption statistics
###############################################################################

sub cm_consumptionUpdate {
    my ($hash, $data, $consumption) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;
    return 0 unless defined $consumption;

    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();

    my $day   = sprintf("%04d-%02d-%02d",
                    $year+1900,
                    $mon+1,
                    $mday);

    my $month = sprintf("%04d-%02d",
                    $year+1900,
                    $mon+1);

    my $yearKey = sprintf("%04d",
                    $year+1900);

    $data->{consumption}{daily}{$day} += $consumption;

    $data->{consumption}{monthly}{$month} += $consumption;

    $data->{consumption}{yearly}{$yearKey} += $consumption;

    return 1;
}

1;
