package ConsumptionManager::Defaults;

use strict;
use warnings;
use Exporter 'import';
use constant;

our @EXPORT_OK = qw(
    CM_SCHEMA_VERSION
    CM_VERSION
    CM_DEFAULT_DECIMALS
    CM_DEFAULT_CURRENCY
);

use constant CM_SCHEMA_VERSION   => 1;
use constant CM_VERSION          => '0.2.0';

use constant CM_DEFAULT_DECIMALS => 3;
use constant CM_DEFAULT_CURRENCY => 'EUR';

use constant CM_DEFAULT_POWER_TIMEOUT => 300;

1;
