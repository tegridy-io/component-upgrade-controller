// main template for upgrade-controller
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.upgrade_controller;
local appName = 'upgrade-conttroller';

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/name': params.namespace,
      'pod-security.kubernetes.io/enforce': 'privileged',
    },
  },
};


// RBAC

local serviceAccount = kube.ServiceAccount(appName) {
  metadata+: {
    namespace: params.namespace,
  },
};

local clusterRoleBinding = kube.ClusterRoleBinding(appName) {
  subjects_: [ serviceAccount ],
  roleRef: {
    apiGroup: 'rbac.authorization.k8s.io',
    kind: 'ClusterRole',
    name: 'cluster-admin',
  },
};


// Deployment

local deployment = kube.Deployment(appName) {
  spec+: {
    replicas: params.replicaCount,
    template+: {
      spec+: {
        serviceAccountName: appName,
        securityContext: {
          seccompProfile: { type: 'RuntimeDefault' },
        },
        affinity: {
          nodeAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: {
              nodeSelectorTerms: [ {
                matchExpressions: [ {
                  key: 'node-role.kubernetes.io/control-plane',
                  operator: 'Exists',
                } ],
              } ],
            },
          },
        },
        containers_:: {
          default: kube.Container(appName) {
            image: '%(registry)s/%(repository)s:%(tag)s' % params.images.upgrade_controller,
            env_:: {
              SYSTEM_UPGRADE_CONTROLLER_NAME: { fieldRef: { apiVersion: 'v1', fieldPath: "metadata.labels['name']" } },
              SYSTEM_UPGRADE_CONTROLLER_NAMESPACE: { fieldRef: { apiVersion: 'v1', fieldPath: 'metadata.namespace' } },
            },
            envFrom: [
              { configMapRef: { name: appName } },
            ],
            volumeMounts_:: {
              'etc-ssl': { mountPath: '/etc/ssl', readOnly: true },
              'etc-pki': { mountPath: '/etc/pki', readOnly: true },
              'etc-ca-certificates': { mountPath: '/etc/ca-certificates', readOnly: true },
              tmp: { mountPath: '/tmp' },
            },
            resources: params.resources,
            securityContext: {
              runAsNonRoot: true,
              allowPrivilegeEscalation: false,
              capabilities: { drop: [ 'ALL' ] },
            },
          },
        },
        tolerations: [
          {
            key: 'CriticalAddonsOnly',
            operator: 'Exists',
          },
          {
            key: 'node-role.kubernetes.io/master',
            operator: 'Exists',
            effect: 'NoSchedule',
          },
          {
            key: 'node-role.kubernetes.io/controlplane',
            operator: 'Exists',
            effect: 'NoSchedule',
          },
          {
            key: 'node-role.kubernetes.io/control-plane',
            operator: 'Exists',
            effect: 'NoSchedule',
          },
          {
            key: 'node-role.kubernetes.io/etcd',
            operator: 'Exists',
            effect: 'NoExecute',
          },
        ],
        volumes_:: {
          'etc-ssl': { hostpath: { path: '/etc/ssl', type: 'DirectoryOrCreate' } },
          'etc-pki': { hostpath: { path: '/etc/pki', type: 'DirectoryOrCreate' } },
          'etc-ca-certificates': { hostpath: { path: '/etc/ca-certificates', type: 'DirectoryOrCreate' } },
          tmp: { emptyDir: {} },
        },
      },
    },
  },
};

local configmap = kube.ConfigMap(appName) {
  metadata+: {
    namespace: params.namespace,
  },
  data: {
    SYSTEM_UPGRADE_CONTROLLER_DEBUG: 'false',
    SYSTEM_UPGRADE_CONTROLLER_THREADS: '2',
    SYSTEM_UPGRADE_JOB_ACTIVE_DEADLINE_SECONDS: '900',
    SYSTEM_UPGRADE_JOB_BACKOFF_LIMIT: '99',
    SYSTEM_UPGRADE_JOB_IMAGE_PULL_POLICY: 'Always',
    SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE: '%(registry)s/%(repository)s:%(tag)s' % params.images.kubectl,
    SYSTEM_UPGRADE_JOB_PRIVILEGED: 'true',
    SYSTEM_UPGRADE_JOB_TTL_SECONDS_AFTER_FINISH: '900',
    SYSTEM_UPGRADE_PLAN_POLLING_INTERVAL: '15m',
  },
};


// Plan

local plan(name) = kube._Object('upgrade.cattle.io/v1', 'Plan', name) {
  metadata+: {
    namespace: params.namespace,
  },
  spec: {
    concurrency: 1,
    cordon: true,
    serviceAccountName: appName,
  },
};

local groups = if std.length(params.groups) > 0 then params.groups else { default: {} };

local plansRelease = [
  local name = if group == 'default' then 'release-upgrade' else 'release-upgrade-%s' % group;
  local tolerations = std.get(groups[group], 'tolerations', {});
  local labels = std.get(groups[group], 'labels', {});
  plan(name) {
    spec+: {
      version: params.release.version,
      upgrade: {
        image: params.release.image,
      },
      nodeSelector: {
        matchExpressions: [
          {
            key: 'release-upgrade',
            operator: 'NotIn',
            values: [ 'disabled', 'false' ],
          },
        ] + [
          {
            key: label,
            operator: 'Exists',
          }
          for label in std.objectFields(labels)
        ],
      },
      [if std.length(tolerations) > 0 then 'tolerations']: tolerations,
    },
  }
  for group in std.objectFields(groups)
];


// Define outputs below
{
  '00_namespace': namespace,
  '10_deployment': deployment,
  '10_configmap': configmap,
  '10_rbac': [ serviceAccount, clusterRoleBinding ],
  [if params.release.version != '' then '20_plans_release']: plansRelease,
}
