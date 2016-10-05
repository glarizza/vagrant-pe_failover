# Vagrant environment for pe\_failover module testing

## Nodes within the stack

This Vagrant stack will stand up four machines:

* Primary (active) monolithic Puppet master
  * `puppetmaster1.puppet.vm`
* Secondary (passive) monolithic Puppet master
  * `puppetmaster1.puppet.vm`
* Puppet agent nodes
  * `agent1.puppet.vm`
  * `agent2.puppet.vm`

## Detailed instructions for bringing up the stack

* Bring up all nodes with Vagrant provisioning
  * `vagrant up`
  * This will bring up ALL nodes, however Puppet will not be installed on the
    passive master and the stack is not yet configured for failover
  * Because of the wonder of Vagrant provisioners, this step will:
    * Install the `pe_failover` module and all dependencies on both masters
    * Set a host entry of `puppet` pointing to the active master
    * Set a host entry for the passive master on the active master
      * NOTE: This is hardcoded based on IP address and will definitely need to
        change. The host entry is necessary before classification with the
        `pe_failover` class or that code will fail (because it won't be able to
        find the passive master)
    * Declare the `pe_failover` class on the active master and set
      `puppetmaster2.puppet.vm` as the passive master and PDB peer
    * Install Puppet on both agent nodes
* Retrieve the `pe-transfer` user's public key
  * (from the active master) `cp -f /home/pe-transfer/.ssh/pe_failover_id_rsa.pub
    /vagrant/public_keys/pe_failover_id_rsa.pub`
  * I recommend storing it in the `/vagrant/public_keys` directory because we will refer to it
    a couple of times and both nodes will eventually need access
* Test ssh `known_hosts` setup
  * Within the module there is code to add the passive master's host key into
    the `pe-transfer` user's `known_hosts` file. I've had issues where I needed
    to actually attempt the ssh FIRST or else the script to sync certs has hung
    waiting for host key acceptance. Test the ssh connection with the
    following:
    * `su - pe-transfer && ssh puppetmaster2.puppet.vm`
      * If it works correctly you should be prompted for a password - just exit
        out with `control + c`
* Classify the Passive node with the `pe_failover` module
  * (from the passive master) `puppet apply -e "include pe_failover; class{pe_failover::passive: auth_key
    => \"$(cat /vagrant/public_keys/pe_failover_id_rsa.pub)\"}"`
    * This reads the public key from `/vagrant/public_keys`, but modify as
      necessary
* Force a CA sync and verify synchronization
  * (from the active master) `touch
    /etc/puppetlabs/puppet/ssl/ca/signed/forcesync`
  * From the PASSIVE master, inspect the `/etc/puppetlabs/puppet/ssl/ca/signed`
    directory and ensure there are certificates from the active master (i.e. if
    files exist in this directory you are good)
    * If this directory does NOT exist, check syslog for any script errors
      * The script is located in `/opt/pe_failover/scripts`
      * Usually this is a host key acceptance issue, so try to ssh from the
        active master to the passive master AS THE `pe-transfer` USER to ensure
        host keys are accepted
* Remove the CA sync file
  * (from the active master) `rm
    /etc/puppetlabs/puppet/ssl/ca/signed/forcesync`
* Pad the `serial` file on the active master
  * (from the active master) open `/etc/puppetlabs/puppet/ssl/ca/serial` and
    replace whatever is in the file with: `186A0(100,000)`
  * This will ensure that the active master issues certificates with unique
    serial numbers from the passive master (and will also ensure that during
    failover the passive master can still issue certificates that don't
    conflict with the active master)
* Configure the passive master to be a monolithic PE master
  * **NOTE: READ NOTES BELOW ON MANUAL INSTALLATION IF YOU ARE TRYING TO DO
    THIS OUTSIDE OF VAGRANT!**
  * There should NOT be any outstanding/existing certificate signing requests
    from the passive master - the way it was installed should ensure that
    `puppet agent` was NEVER run and thus a certificate signing request was
    never issued anywhere
  * Since you're using Vagrant, we can re-use the existing `pe.conf` from the
    active master and do an install by invoking the installer from the tarball
    that the `pe_build` Vagrant plugin downloads with the following command:
    * `/vagrant/.pe_build/puppet-enterprise-2016.2.1-el-6-x86_64/puppet-enterprise-installer
      -c /vagrant/answer_files/pe.conf`
  * When the installer completes, it asks you to run Puppet to finish the
    installation
    * `puppet agent -t`
  * Next setup the `pe_failover` nodegroups that will automatically classify
    the active and passive node with the following command:
    * (from the passive master) `puppet apply -e "include pe_failover; include
      pe_failover::active::classification; include
      pe_failover::active::scripts"`
* Test and verify
  * Running Puppet from agents
    * Ensure Puppet is setup to point to the alias of 'puppet'
      * `puppet agent --configprint server`
    * Ensure `/etc/hosts` has a record for `puppet` that maps to the active
      master
    * Perform a Puppet run
      * `puppet agent -t`
    * Change the alias in `/etc/hosts` to point to the passive master and then
      run Puppet again
      * This should be successful
* Both Puppet masters should be setup for their active/passive roles

## Failover steps between active/passive master

* Promote the passive master to be the new active master
  * (from the current passive master - `puppetmaster2`) `puppet apply -e
    'include pe_failover; class{pe_failover::active: passive_master =>
    "puppetmaster1.puppet.vm", pdb_peer =>  "puppetmaster1.puppet.vm"}'`
* Demote the active master to be the new passive master
  * (from the former active master - `puppetmaster1`) `puppet apply -e "include
    pe_failover; class{pe_failover::passive: pdb_peer =>
    'puppetmaster2.puppet.vm', auth_key => \"$(cat
    /vagrant/public_keys/pe_failover_id_rsa.pub)\"}"`
* Perform a Puppet run on both hosts
* Change the load balancer/DNS CNAME/host entry
  * Depending on your balancing strategy, ensure that your current tools point
    to the NEW active master of `puppetmaster2.puppet.vm`
* Perform Puppet runs as usual

## PuppetDB Replication (Requires PE 2016.4.x)

### CAVEAT ABOUT FUNCTIONALITY

PuppetDB has an application-layer replication configuration that is currently
in beta. It can be ENABLED all the way back to PE 2016.2.x, I believe, however
the `puppet_enterprise` module has/had a bug where exported certificate
whitelist resources didn't have sufficiently unique titles, and thus if you
setup two monolithic PE masters and replicated then, all Puppet runs would fail
with the following error:

```
[root@puppetmaster2 vagrant]# puppet agent -t
Info: Using configured environment 'production'
Info: Retrieving pluginfacts
Info: Retrieving plugin
Info: Loading facts
Error: Could not retrieve catalog from remote server: Error 400 on SERVER:
A duplicate resource was found while collecting exported resources, with the
type and title Puppet_enterprise::Certs::Rbac_whitelist_entry[export: orchestra
tor-pe-internal-orchestrator-for-rbac-whitelist] on node
puppetmaster2.puppet.vm
Warning: Not using cache on failed catalog
Error: Could not retrieve catalog; skipping run
```

If you see this error and you did NOT expect it (or didn't think you enabled
replication), the solution (as of 10/5/2016) is to ensure that the `$pdb_peer`
parameter is NOT passed/available to either the `pe_failover::active` or the
`pe_failover::passive` class. By default, currently, it looks for a fact called
`$::pe_failover_pdb_peer` which does/can get set. Check to see if this fact is
set with the following command:

`facter -p pe_failover_pdb_peer`

If a value is returned, check the file `/opt/puppetlabs/facter/facts.d/pe_failover.yaml`
for a value. This file is created by the `pe_failover` module based on facts,
and CREATING this file will CREATE new custom Facter facts, so it's kind of a
chicken/egg situation. Clearing the value out of this file and running Puppet
again should correct the issue.

### Enabling Replication with PE 2016.4.x (and higher)

Setting up PuppetDB Replication with this module requires a couple of steps
(which, by all accounts, may already be done):

* Classify the active/passive master with the correct `pe_failover` class
  * This should ALREADY have been done above when the PE Console nodegroups
    were created.
  * Open the PE Console and ensure there are groups created that
    classify the active and passive masters with the appropriate class
  * NOTE: The code that enables replication requires that the `puppet_enterprise`
    class ALSO be in the catalog, so trying to do this with `puppet apply` will
    not work.  You must use a classification method that requires `puppet agent`
    (i.e. using the PE console or `site.pp`)
* Ensure `pe_failover::{active,passive}::pdb_peer` has a value
  * This parameter can be explicitly passed, or it will default back to the
    value of the `$::pe_failover_pdb_peer` fact. See the previous section
    about checking for that value and also setting it inside `/opt/puppetlabs/facter/facts.d/pe_failover.yaml`
* Perform a Puppet run

At this point, replication should be enabled! Check that it's functioning by
opening `/var/log/puppetlabs/puppetdb/puppetdb.log` and looking for messages
about replication. The file at `/etc/puppetlabs/puppetdb/conf.d/sync.ini` is
created by the `pe_failover` module and contains the values necessary for
enabling replication, and `/etc/puppetlabs/puppetdb/certificate-whitelist`
on BOTH masters must contain an entry for BOTH the active and passive masters.

## Manual installation steps (i.e doing this without Vagrant)

This repository is obviously optimized for Vagrant, but in the event that you
need to use the `pe_failover` module outside of Vagrant, there are a couple of
key steps that need to happen:

### **PE NEEDS TO BE INSTALLED VERY CAREFULLY ON THE PASSIVE MASTER!!**

When you get to the part about configuring the passive master to be
a monolithic PE master, you'll want to follow these install steps. 
The important thing here is that we want to ensure that the PE installer creates
a certificate for the passive master that contains the correct DNS Alternative
Names (in this case, a dns-alt-name of 'puppet', but in your case, whatever the
cname is of your load balancer or DNS entry). This is set in `pe.conf` with the
value of `"pe_install::puppet_master_dnsaltnames": ["puppet"]`, and you can
find that file in `answer_files/pe.conf` in this repo.

We ALSO need to run Puppet in `puppet apply` mode before we do a full Puppet
Enterprise installation, which means that we will need the `puppet-agent`
package installed first, but we also need to ensure that it doesn't contact an
existing Puppet master and try to generate a certificate signing request before
we do the full PE Monolithic Master installation.

With Vagrant and Redhat, I did this by downloading the PE tarball, expanding
it, and manually creating a yum repo configuration file that maps to the yum
repo inside the expanded tarball. If you expand the PE tarball in `/var/tmp`,
the file you create will look like the following:

```
[pe_install_repo]
name=PuppetLabs PE Install Packages el-6-x86_64
baseurl=file:///var/tmp/puppet-enterprise-2016.2.1-el-6-x86_64/packages/el-6-x86_64
enabled=1
gpgcheck=1
gpgkey=file:///var/tmp/puppet-enterprise-2016.2.1-el-6-x86_64/packages/GPG-KEY-puppetlabs
```

Name this file `/etc/yum.repos.d/pe_install.repo` and then run the following
command as root:

`yum install puppet-agent -y`

That will install the `puppet-agent` package and give you the ability to use
Puppet, but will NOT contact a Puppet master (unless you mess up and run
`puppet agent`...so don't do that until directed).

### Ensure `pe_failover` module and dependencies are available

The only other caveat for manual installation is that you need to ensure that
the `pe_failover` module and all its dependencies are installed BEFORE
attempting to declare the class.


# Puppet Debugging Kit
_The only good bug is a dead bug._

This project provides a batteries-included Vagrant environment for debugging Puppet powered infrastructures.

# Tuning PuppetDB and Puppet Server Together

## Disable gc-interval on PuppetDB

Only one PuppetDB should ever perform GC on the database so each compile master should disable [gc-interval](https://docs.puppet.com/puppetdb/latest/configure.html#gc-interval).

## CPUs = puppet server jrubies + puppetdb command processing threads + 1

In order to prevent a situation in which a thundering herd of traffic would cause puppet server and puppetdb to compete for resources you want to make sure jrubies + command processing threads < # CPUs.

I recommend setting PuppetDB command processing threads to 1 to start with and see if that allows for adequate throughput.  You can monitor the QueueSize in PuppetDB with the [pe_metric_curl_cron_jobs](https://github.com/npwalker/pe_metric_curl_cron_jobs) to make sure you're not seeing a backup of commands.  If you do see a backup then add a command processing thread and reduce by one jruby.

## Set max_connections in PostgreSQL to 1000

Each PuppetDB uses 50 connections to PostgreSQL by default.  So, you need to increase max_connections to allow for all of those connections.

If you are adding more than 4 puppetdb nodes then you might want to consider tuning down the connection pools to reduce the connection overhead on the postgresql side.  There are parameters for read and write connection pool sizes in the puppet_enterprise module.

My understanding is that you need a read connection for each jruby instance and you need roughly 2x command processing threads for write connections.  This assumes the console will use the PuppetDB instance on the MoM for it's read queries.

## Setup

Getting the debugging kit ready for use consists of three steps:

  - Ensure the proper Vagrant plugins are installed.

  - Create VM definitions in `config/vms.yaml`.

  - Clone Puppet Open Source projects to `src/puppetlabs` (optional).

Rake tasks and templates are provided to help with all three steps.

### Install Vagrant Plugins

Two methods are avaible depending on whether a global Vagrant installation, such as provided by the official packages from [vagrantup.com](http://vagrantup.com), is in use:

  - `rake setup:global`:
    This Rake task will add all plugins required by the debugging kit to a global Vagrant installation.

  - `rake setup:sandboxed`:
    This Rake task will use Bundler to create a completely sandboxed Vagrant installation that includes the plugins required by the debugging kit.
    The contents of the sandbox can be customized by creating a `Gemfile.local` that specifies additional gems and Bundler environment parameters.

### Create VM Definitions

Debugging Kit virtual machine definitions are stored in the file `config/vms.yaml` and an example is provided as `config/vms.yaml.example`.
The example can simply be copied to `config/vms.yaml` but it contains a large number of VM definitions which adds some notable lag to Vagrant start-up times.
Start-up lag can be remedied by pruning unwanted definitions after copying the example file.

### Clone Puppet Open Source Projects

The `poss-envpuppet` role is designed to run Puppet in guest machines directly from Git clones located on the host machine at `src/puppetlabs/`.
This role is useful for inspecting and debugging changes in behavior between versions without re-installing packages.
The required Git clones can be created by running the following Rake task:

    rake setup:poss


## Usage

Use of the debugging kit consists of:

  - Creating a new VM definition in `config/vms.yaml`.
    The `box` component determines which Vagrant basebox will be used.
    The default baseboxes can be found in [`data/puppet_debugging_kit/boxes.yaml`](https://github.com/puppetlabs/puppet-debugging-kit/blob/internal/data/puppet_debugging_kit/boxes.yaml).

  - Assigning a list of "roles" that customize the VM behavior.
    The role list can be viewed as a stack in which the last entry is applied first.
    Most VMs start with the `base` role which auto-assigns an IP address and sets up network connectivity.
    The default roles can be found in [`data/puppet_debugging_kit/roles.yaml`](https://github.com/puppetlabs/puppet-debugging-kit/blob/internal/data/puppet_debugging_kit/roles.yaml) and are explained in more detail below.


### PE Specific Roles

There are three roles that assist with creating PE machines:

  - `pe-forward-console`:
    This role sets up a port forward for console accesss from 443 on the guest VM to 4443 on the host machine.
    If some other running VM is already forwarding to 4443 on the host, Vagrant will choose a random port number that will be displayed in the log output when the VM starts up.

  - `pe-<version>-master`:
    This role performs an all-in-one master installation of PE `<version>` on the guest VM.
    When specifying the version number, remove any separators such that `3.2.1` becomes `321`.
    The PE console is configured with username `admin@puppetlabs.com` and password `puppetlabs`.

  - `pe-<version>-agent`:
    This role performs an agent installation of PE `<version>` on the guest VM.
    The agent is configured to contact a master running at `pe-<version>-master.puppetdebug.vlan` --- so ensure a VM with that hostname is configured and running before bringing up any agents.


### POSS Specific Roles

There are a few roles that assist with creating VMs that run Puppet Open Source Software (POSS).

  - `poss-apt-repos`:
    This role configures access to the official repositories at apt.puppetlabs.com for Debian and Ubuntu VMs.

  - `poss-yum-repos`:
    This role configures access to the official repositories at yum.puppetlabs.com for CentOS and Fedora VMs.


## Extending and Contributing

The debugging kit can be thought of as a library of configuration and data for [Oscar](https://github.com/adrienthebo/oscar).
Data is loaded from two sets of YAML files:

```
config
└── *.yaml         # <-- User-specific customizations
data
└── puppet_debugging_kit
    └── *.yaml     # <-- The debugging kit library
```

Everything under `data/puppet_debugging_kit` is loaded first.
In order to avoid merge conflicts when the library is updated, these files should never be edited unless you plan to submit your changes as a pull request.

The contents of `config/*.yaml` are loaded next and can be used to extend or override anything provided by `data/puppet_debugging_kit`.
These files are not tracked by Git and are where user-specific customizations should go.

---
<p align="center">
  <img src="http://i.imgur.com/TFTT0Jh.png" />
</p>
