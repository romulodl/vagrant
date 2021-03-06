require_relative "../errors"
require_relative "../helpers"

module VagrantPlugins
  module Ansible
    module Provisioner

      # This class is a base class where the common functionality shared between
      # both Ansible provisioners are stored.
      # This is **not an actual provisioner**.
      # Instead, {Host} (ansible) or {Guest} (ansible_local) should be used.

      class Base < Vagrant.plugin("2", :provisioner)

        protected

        def initialize(machine, config)
          super

          @command_arguments = []
          @environment_variables = {}
          @inventory_machines = {}
          @inventory_path = nil
        end

        def prepare_common_command_arguments
          # By default we limit by the current machine,
          # but this can be overridden by the `limit` option.
          if config.limit
            @command_arguments << "--limit=#{Helpers::as_list_argument(config.limit)}"
          else
            @command_arguments << "--limit=#{@machine.name}"
          end

          @command_arguments << "--inventory-file=#{inventory_path}"
          @command_arguments << "--extra-vars=#{extra_vars_argument}" if config.extra_vars
          @command_arguments << "--sudo" if config.sudo
          @command_arguments << "--sudo-user=#{config.sudo_user}" if config.sudo_user
          @command_arguments << "#{verbosity_argument}" if verbosity_is_enabled?
          @command_arguments << "--vault-password-file=#{config.vault_password_file}" if config.vault_password_file
          @command_arguments << "--tags=#{Helpers::as_list_argument(config.tags)}" if config.tags
          @command_arguments << "--skip-tags=#{Helpers::as_list_argument(config.skip_tags)}" if config.skip_tags
          @command_arguments << "--start-at-task=#{config.start_at_task}" if config.start_at_task

          # Finally, add the raw configuration options, which has the highest precedence
          # and can therefore potentially override any other options of this provisioner.
          @command_arguments.concat(Helpers::as_array(config.raw_arguments)) if config.raw_arguments
        end

        def prepare_common_environment_variables
          # Ensure Ansible output isn't buffered so that we receive output
          # on a task-by-task basis.
          @environment_variables["PYTHONUNBUFFERED"] = 1

          # When Ansible output is piped in Vagrant integration, its default colorization is
          # automatically disabled and the only way to re-enable colors is to use ANSIBLE_FORCE_COLOR.
          @environment_variables["ANSIBLE_FORCE_COLOR"] = "true" if @machine.env.ui.color?
          # Setting ANSIBLE_NOCOLOR is "unnecessary" at the moment, but this could change in the future
          # (e.g. local provisioner [GH-2103], possible change in vagrant/ansible integration, etc.)
          @environment_variables["ANSIBLE_NOCOLOR"] = "true" if !@machine.env.ui.color?
        end

        # Auto-generate "safe" inventory file based on Vagrantfile,
        # unless inventory_path is explicitly provided
        def inventory_path
          if config.inventory_path
            config.inventory_path
          else
            @inventory_path ||= generate_inventory
          end
        end

        def generate_inventory
          inventory = "# Generated by Vagrant\n\n"

            # This "abstract" step must fill the @inventory_machines list
            # and return the list of supported host(s)
          inventory += generate_inventory_machines

          inventory += generate_inventory_groups

          # This "abstract" step must create the inventory file and
          # return its location path
          # TODO: explain possible race conditions, etc.
          @inventory_path = ship_generated_inventory(inventory)
        end

        # Write out groups information.
        # All defined groups will be included, but only supported
        # machines and defined child groups will be included.
        # Group variables are intentionally skipped.
        def generate_inventory_groups
          groups_of_groups = {}
          defined_groups = []
          inventory_groups = ""

          config.groups.each_pair do |gname, gmembers|
            # Require that gmembers be an array
            # (easier to be tolerant and avoid error management of few value)
            gmembers = [gmembers] if !gmembers.is_a?(Array)

            if gname.end_with?(":children")
              groups_of_groups[gname] = gmembers
              defined_groups << gname.sub(/:children$/, '')
            elsif !gname.include?(':vars')
              defined_groups << gname
              inventory_groups += "\n[#{gname}]\n"
              gmembers.each do |gm|
                inventory_groups += "#{gm}\n" if @inventory_machines.include?(gm.to_sym)
              end
            end
          end

          defined_groups.uniq!
          groups_of_groups.each_pair do |gname, gmembers|
            inventory_groups += "\n[#{gname}]\n"
            gmembers.each do |gm|
              inventory_groups += "#{gm}\n" if defined_groups.include?(gm)
            end
          end

          return inventory_groups
        end

        def extra_vars_argument
          if config.extra_vars.kind_of?(String) and config.extra_vars =~ /^@.+$/
            # A JSON or YAML file is referenced.
            config.extra_vars
          else
            # Expected to be a Hash after config validation.
            config.extra_vars.to_json
          end
        end

        def get_galaxy_role_file(basedir)
          File.expand_path(config.galaxy_role_file, basedir)
        end

        def get_galaxy_roles_path(basedir)
          if config.galaxy_roles_path
            File.expand_path(config.galaxy_roles_path, basedir)
          else
            File.join(Pathname.new(config.playbook).expand_path(basedir).parent, 'roles')
          end
        end

        def ui_running_ansible_command(name, command)
          @machine.ui.detail I18n.t("vagrant.provisioners.ansible.running_#{name}")
          if verbosity_is_enabled?
            # Show the ansible command in use
            @machine.env.ui.detail command
          end
        end

        def verbosity_is_enabled?
          config.verbose && !config.verbose.to_s.empty?
        end

        def verbosity_argument
          if config.verbose.to_s =~ /^-?(v+)$/
            "-#{$+}"
          else
            # safe default, in case input strays
            '-v'
          end
        end

      end
    end
  end
end
