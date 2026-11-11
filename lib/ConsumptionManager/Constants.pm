package ConsumptionManager::Constants;

use strict;
use warnings;
use Exporter 'import';
use constant;

our @EXPORT_OK = qw(
    CM_SCHEMA_VERSION
    CM_VERSION
    CM_DEFAULT_DECIMALS
    CM_DEFAULT_CURRENCY
    CM_DEFAULT_POWER_TIMEOUT
);

use constant CM_SCHEMA_VERSION   => 15;
use constant CM_VERSION          => '1.1.0-dev5';

use constant CM_DEFAULT_DECIMALS => 3;
use constant CM_DEFAULT_CURRENCY => 'EUR';

use constant CM_DEFAULT_POWER_TIMEOUT => 300;

=head1 NAME

ConsumptionManager::Constants

=head1 DESCRIPTION

Constant values for the ConsumptionManager.

=cut

1;
