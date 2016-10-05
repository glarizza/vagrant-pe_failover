  pe_node_group { 'PE Compile Master w/ PuppetDB':
    parent  => 'PE Infrastructure',
    pinned  => ['compile-master-puppetdb'],
    classes => {
      'puppet_enterprise::profile::master' => { 'puppetdb_host' => '${fqdn}', 'puppetdb_port' => '8081' },
      'puppet_enterprise::profile::master::mcollective' => {},
      'puppet_enterprise::profile::mcollective::peadmin' => {},
      'puppet_enterprise::profile::puppetdb' => {},
    }
  }

  pe_node_group { 'PE External Postgres':
    ensure             => 'present',
    classes            => {'puppet_enterprise::profile::database' => {}},
    parent             => 'PE Infrastructure',
    pinned             => ['external-postgres'],
  }

  pe_node_group { 'PE Infrastructure':
    ensure             => 'present',
    classes            => {
                            'puppet_enterprise' => {
                              'certificate_authority_host'   => 'pe-mom',
                              'console_host'                 => 'pe-mom',
                              'database_host'                => 'external-postgres',
                              'mcollective_middleware_hosts' => ['pe-mom'],
                              'pcp_broker_host'              => 'pe-mom',
                              'puppet_master_host'           => 'pe-mom',
                              # NOTE: The below line is the ONLY change necessary
                              # as $puppetdb_host needs to include every node that
                              # will have a PuppetDB installation
                              'puppetdb_host'                => ['pe-mom', 'compile-master-puppetdb'],
                              'puppetdb_port'                => ['8081', '8081']
                            }
                          },
    parent             => 'All Nodes',
  }
