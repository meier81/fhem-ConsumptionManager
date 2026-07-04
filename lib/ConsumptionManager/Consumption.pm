package ConsumptionManager::Consumption;

use strict;
use warnings;
use Exporter 'import';

use ConsumptionManager::Constants qw(
    CM_VERSION
);

use ConsumptionManager::Utils qw(
    cm_dateKeys
);

our @EXPORT_OK = qw(
    cm_consumptionUpdate
    cm_consumptionToday
    cm_consumptionMonth
    cm_consumptionYear
    cm_consumptionYesterday
    cm_consumptionLastMonth
    cm_consumptionLastYear
);

our $VERSION = CM_VERSION;

=head1 NAME

ConsumptionManager::Consumption

=head1 DESCRIPTION

Consumption calculations.

=cut

###############################################################################
# Update consumption values
###############################################################################

sub cm_consumptionUpdate {
    my (
        $hash,
        $data,
        $oldCounter,
        $newCounter,
        $consumption
    ) = @_;

    return 0 unless defined $hash;
    return 0 unless defined $data;
    return 0 unless defined $consumption;

    my ($day, $month, $yearKey) = cm_dateKeys();

    ###########################################################################
    # Period rollover
    ###########################################################################

    cm_consumptionCheckDay($data, $day);
    cm_consumptionCheckMonth($data, $month);
    cm_consumptionCheckYear($data, $yearKey);

    ###########################################################################
    # Initialize counters
    ###########################################################################

    $data->{consumption}{daily}{$day}{value} //= 0;
    $data->{consumption}{monthly}{$month}{value} //= 0;
    $data->{consumption}{yearly}{$yearKey}{value} //= 0;

    ###########################################################################
    # Update counters
    ###########################################################################

    $data->{consumption}{daily}{$day}{value} += $consumption;
    $data->{consumption}{monthly}{$month}{value} += $consumption;
    $data->{consumption}{yearly}{$yearKey}{value} += $consumption;

    return 1;
}

###############################################################################
# Return today's consumption
###############################################################################

sub cm_consumptionToday {

    my ($data) = @_;

    return 0 unless defined $data;

    my ($day) = cm_dateKeys();

    return $data->{consumption}{daily}{$day}{value} // 0;
}

###############################################################################
# Return current month's consumption
###############################################################################

sub cm_consumptionMonth {

    my ($data) = @_;

    return 0 unless defined $data;

    my (undef, $month) = cm_dateKeys();

    return $data->{consumption}{monthly}{$month}{value} // 0;
}

###############################################################################
# Return current year's consumption
###############################################################################

sub cm_consumptionYear {

    my ($data) = @_;

    return 0 unless defined $data;

    my (undef, undef, $yearKey) = cm_dateKeys();

    return $data->{consumption}{yearly}{$yearKey}{value} // 0;
}

###############################################################################
# Return yesterday's consumption
###############################################################################

sub cm_consumptionYesterday {

    my ($data) = @_;

    return 0 unless defined $data;

    return $data->{consumption}{yesterday} // 0;
}

###############################################################################
# Return last month's consumption
###############################################################################

sub cm_consumptionLastMonth {

    my ($data) = @_;

    return 0 unless defined $data;

    return $data->{consumption}{lastMonthValue} // 0;
}

###############################################################################
# Return last year's consumption
###############################################################################

sub cm_consumptionLastYear {

    my ($data) = @_;

    return 0 unless defined $data;

    return $data->{consumption}{lastYearValue} // 0;
}

###############################################################################
# Check day rollover
###############################################################################

sub cm_consumptionCheckDay {

    my ($data, $day) = @_;

    return unless defined $data;

    my $lastDay = $data->{consumption}{lastDayKey} // '';

    if ($lastDay ne '' && $lastDay ne $day) {

        $data->{consumption}{yesterday} =
            $data->{consumption}{daily}{$lastDay}{value} // 0;
    }

    $data->{consumption}{lastDayKey} = $day;

    return;
}

###############################################################################
# Check month rollover
###############################################################################

sub cm_consumptionCheckMonth {

    my ($data, $month) = @_;

    return unless defined $data;

    my $lastMonth = $data->{consumption}{lastMonthKey} // '';

    if ($lastMonth ne '' && $lastMonth ne $month) {

        $data->{consumption}{lastMonthValue} =
            $data->{consumption}{monthly}{$lastMonth}{value} // 0;
    }

    $data->{consumption}{lastMonthKey} = $month;

    return;
}

###############################################################################
# Check year rollover
###############################################################################

sub cm_consumptionCheckYear {

    my ($data, $year) = @_;

    return unless defined $data;

    my $lastYear = $data->{consumption}{lastYearKey} // '';

    if ($lastYear ne '' && $lastYear ne $year) {

        $data->{consumption}{lastYearValue} =
            $data->{consumption}{yearly}{$lastYear}{value} // 0;
    }

    $data->{consumption}{lastYearKey} = $year;

    return;
}

1;
