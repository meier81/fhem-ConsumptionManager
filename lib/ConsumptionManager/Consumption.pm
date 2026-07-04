package ConsumptionManager::Consumption;

use strict;
use warnings;
use Exporter 'import';
use ConsumptionManager::Utils qw(cm_dateKeys);

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
    my ($hash, $data, $oldCounter, $newCounter, $consumption) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;
    return 0 unless defined $consumption;

    my ($day, $month, $yearKey) = cm_dateKeys();

    $data->{consumption}{daily}{$day} += $consumption;

    $data->{consumption}{monthly}{$month} += $consumption;

    $data->{consumption}{yearly}{$yearKey} += $consumption;

    return 1;
}

1;
