use strict;
use warnings;
use Test::More;
use lib 'lib';

use ConsumptionManager::Billing qw(
    cm_billingCalculatePeriod
    cm_billingCalculatePreviousPeriod
);

my $data = {
    meter => {
        current => 150.00,
        virtual => 150.00,
        offset  => 0,
    },
    meterChanges => [],
    consumption => {
        dayKey         => '2026-08-15',
        dayBaseline    => 149.00,
        yesterday      => 2.00,
        monthKey       => '2026-08',
        monthBaseline  => 140.00,
        lastMonthValue => 20.00,
        yearKey        => '2026',
        yearBaseline   => 100.00,
        lastYearValue  => 80.00,
    },
    tariffs => [
        {
            id => 1,
            validFrom => '2025-01-01',
            validTo => '',
            workPrice => 0.10,
            basePrice => 0,
            basePriceUnit => 'year',
            currency => 'EUR',
            unitCounter => 'm3',
            unitBilling => 'kWh',
            calorificValue => 10,
            stateNumber => 0.95,
            assessmentFactor => 1,
            surfaceUsageArea => 0,
            surfaceUsagePrice => 0,
            surfaceRecurringArea => 0,
            surfaceRecurringPrice => 0,
        },
    ],
    advances => [],
    settings => { currency => 'EUR' },
};

my $today = cm_billingCalculatePeriod($data, 'today', '2026-08-15');
is($today->{status}, 'active', 'today active');
cmp_ok(abs($today->{billingConsumption} - 9.5), '<', 0.000001, 'today energy kWh');

my $month = cm_billingCalculatePeriod($data, 'month', '2026-08-15');
cmp_ok(abs($month->{billingConsumption} - 95), '<', 0.000001, 'month energy kWh');

my $year = cm_billingCalculatePeriod($data, 'year', '2026-08-15');
cmp_ok(abs($year->{billingConsumption} - 475), '<', 0.000001, 'year energy kWh');

my $yesterday = cm_billingCalculatePreviousPeriod($data, 'yesterday');
cmp_ok(abs($yesterday->{billingConsumption} - 19), '<', 0.000001, 'yesterday energy kWh');

my $lastMonth = cm_billingCalculatePreviousPeriod($data, 'lastMonth');
cmp_ok(abs($lastMonth->{billingConsumption} - 190), '<', 0.000001, 'last month energy kWh');

my $lastYear = cm_billingCalculatePreviousPeriod($data, 'lastYear');
cmp_ok(abs($lastYear->{billingConsumption} - 760), '<', 0.000001, 'last year energy kWh');


my $multi = {
    %{$data},
    meter => { %{$data->{meter}} },
    consumption => { %{$data->{consumption}} },
    advances => [],
    settings => { currency => 'EUR' },
    tariffs => [
        {
            %{$data->{tariffs}[0]},
            id => 1,
            validFrom => '2025-01-01',
            validTo => '2026-06-30',
        },
        {
            %{$data->{tariffs}[0]},
            id => 2,
            validFrom => '2026-07-01',
            validTo => '',
            calorificValue => 11,
            stateNumber => 1,
            counterSnapshot => 130,
            counterSnapshotDate => '2026-07-01',
            counterSnapshotExact => 1,
        },
    ],
};
my $multiYear = cm_billingCalculatePeriod($multi, 'year', '2026-08-15');
is($multiYear->{status}, 'active', 'multi-tariff year active');
cmp_ok(abs($multiYear->{billingConsumption} - 505), '<', 0.000001,
    'year energy uses historical calorific value and state number');

done_testing();
