local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.upgrade_controller;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('upgrade-controller', params.namespace);

{
  'upgrade-controller': app,
}
