use strict;
use warnings;
use Test::More;
use lib 'lib';
use ConsumptionManager::Storage ();
use ConsumptionManager::Consumption qw(cm_consumptionToday cm_consumptionMonth cm_consumptionYear);
use ConsumptionManager::Utils qw(cm_dateKeys);

my ($day,$month,$year)=cm_dateKeys();
my $data = {
 schema=>13,
 meta=>{}, device=>{},
 meter=>{
   current=>61.5039, virtual=>1114.5927, offset=>1053.0888,
   yearBaselines=>{$year=>1018.2225},
   monthBaselines=>{$month=>58.0000},
   firstCounter=>12, firstTimestamp=>1, previous=>61, lastConsumption=>0.5,
 },
 meterChanges=>[{
   date=>'2026-03-15', oldCounter=>1070, newCounter=>16.9112,
   offsetDelta=>1053.0888,
 }],
 consumption=>{
   lastDayKey=>$day,lastMonthKey=>$month,lastYearKey=>$year,
   yesterday=>1.1,lastMonthValue=>12.2,lastYearValue=>100,
   daily=>{$day=>{value=>2.7418}},
   monthly=>{$month=>{value=>2.7418}},
   yearly=>{$year=>{value=>2.7418}},
 },
 tariffs=>[], advances=>[], tariffEditor=>{}, advanceEditor=>{}, settings=>{},
};

my $m = ConsumptionManager::Storage::cm_storageMigrate({}, $data);
ok($m, 'migration returned data');
ok(!exists $m->{consumption}{daily}, 'daily history removed');
ok(!exists $m->{consumption}{monthly}, 'monthly history removed');
ok(!exists $m->{consumption}{yearly}, 'yearly history removed');
ok(!exists $m->{meter}{yearBaselines}, 'old year baseline hash removed');
ok(!exists $m->{meter}{monthBaselines}, 'old month baseline hash removed');
ok(!exists $m->{meter}{firstCounter}, 'firstCounter removed');
ok(!exists $m->{meter}{lastConsumption}, 'lastConsumption removed');
cmp_ok(abs(cm_consumptionYear($m)-96.3702), '<', 0.000001, 'year baseline migrated to virtual scale');
cmp_ok(abs(cm_consumptionMonth($m)-3.5039), '<', 0.000001, 'month baseline migrated to virtual scale');
cmp_ok(abs(cm_consumptionToday($m)-2.7418), '<', 0.000001, 'today preserved via inferred baseline');
is($m->{consumption}{yesterday},1.1,'yesterday preserved');
is($m->{consumption}{lastMonthValue},12.2,'last month preserved');
is($m->{consumption}{lastYearValue},100,'last year preserved');

done_testing();
