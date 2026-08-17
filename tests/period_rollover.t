use strict;
use warnings;
use Test::More;
use lib 'lib';
use ConsumptionManager::Consumption qw(
    cm_consumptionUpdate cm_consumptionToday cm_consumptionYesterday
    cm_consumptionMonth cm_consumptionLastMonth cm_consumptionYear cm_consumptionLastYear
);

my $data = {
    meter => { current => 110, virtual => 110, offset => 0 },
    consumption => {
        dayKey=>'2026-08-31', dayBaseline=>100, yesterday=>4,
        monthKey=>'2026-08', monthBaseline=>80, lastMonthValue=>20,
        yearKey=>'2026', yearBaseline=>50, lastYearValue=>40,
    },
};

{
    no warnings 'redefine';
    local *ConsumptionManager::Consumption::cm_dateKeys = sub { ('2027-01-01','2027-01','2027') };
    ok(cm_consumptionUpdate($data, 110, 112), 'roll periods');
}
$data->{meter}{current}=112; $data->{meter}{virtual}=112;

is($data->{consumption}{yesterday},10,'previous day captured');
is($data->{consumption}{lastMonthValue},30,'previous month captured');
is($data->{consumption}{lastYearValue},60,'previous year captured');
is($data->{consumption}{dayBaseline},110,'new day baseline');
is($data->{consumption}{monthBaseline},110,'new month baseline');
is($data->{consumption}{yearBaseline},110,'new year baseline');
is(cm_consumptionToday($data),2,'new day consumption');
is(cm_consumptionMonth($data),2,'new month consumption');
is(cm_consumptionYear($data),2,'new year consumption');

done_testing();
