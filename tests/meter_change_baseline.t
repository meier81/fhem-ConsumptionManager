use strict;
use warnings;
use Test::More;
use lib 'lib';
use ConsumptionManager::Meter qw(
    cm_meterRegisterChange
    cm_meterSetYearBaseline
    cm_meterSetMonthBaseline
    cm_meterUpdate
);
use ConsumptionManager::Consumption qw(
    cm_consumptionToday
    cm_consumptionMonth
    cm_consumptionYear
);
use ConsumptionManager::Utils qw(cm_today cm_month cm_year);

my $data = {
    meter => {
        current => undef,
        offset => 0,
        virtual => undef,
        lastTimestamp => 0,
        lastUpdate => '',
        powerCurrent => 0,
    },
    meterChanges => [],
    tariffs => [],
    consumption => {
        dayKey => '', dayBaseline => undef, yesterday => 0,
        monthKey => '', monthBaseline => undef, lastMonthValue => 0,
        yearKey => '', yearBaseline => undef, lastYearValue => 0,
    },
};

ok(cm_meterRegisterChange($data, '2026-03-15', 1070, 16.9112, 'test'), 'meter change');
ok(cm_meterSetYearBaseline($data, cm_year(), 1018.2225), 'year baseline before first live value');
ok(cm_meterSetMonthBaseline($data, cm_month(), 58.0000), 'month baseline before first live value');
ok(cm_meterUpdate({}, $data, 61.5039), 'first live value');

cmp_ok(abs(cm_consumptionYear($data) - 96.3702), '<', 0.000001, 'year consumption uses virtual scale');
cmp_ok(abs(cm_consumptionMonth($data) - 3.5039), '<', 0.000001, 'month consumption uses virtual scale');
is(cm_consumptionToday($data), 0, 'first live value starts current day at zero');

ok(cm_meterUpdate({}, $data, 62.0039), 'second live value');
cmp_ok(abs(cm_consumptionToday($data) - 0.5), '<', 0.000001, 'today derived from day baseline');
cmp_ok(abs(cm_consumptionMonth($data) - 4.0039), '<', 0.000001, 'month derived from month baseline');
cmp_ok(abs(cm_consumptionYear($data) - 96.8702), '<', 0.000001, 'year derived from year baseline');

ok(!exists $data->{consumption}{daily}, 'no daily history');
ok(!exists $data->{consumption}{monthly}, 'no monthly history');
ok(!exists $data->{consumption}{yearly}, 'no yearly history');

done_testing();
