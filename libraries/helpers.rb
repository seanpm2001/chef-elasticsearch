require 'chef/search/query'

module Elasticsearch
  module Helpers
    def members
      return new_resource.members if new_resource.members

      output = {}
      query  = "chef_environment:#{node.chef_environment} AND elasticsearch_cluster:#{current.cluster}"
      all    = ::Chef::Search::Query.new.search(:node, query).first

      %w(client data master marvel).each do |type|
        output[type.to_sym] = all.select do |member|
          member[:elasticsearch][:type].match(/type/i)
        end
      end

      # include self on initial search
      unless output[current.type.to_sym].map(&:name).include?(node.name)
        output[current.type.to_sym] << node
      end

      output.each do |type, members|
        members.map! do |member|
          ip   = address_for_member(member)
          port = current.transport_port
          "#{ip}:#{port}"
        end
      end
    end

    # Returns address associated with given interface.
    # @return [String] IP address of provided interface.
    def address
      node.network.interfaces[current.interface].addresses.select do |_, conf|
        conf[:family] == 'inet'
      end.keys.first
    end

    def address_for_member(member)
      return member[:ipaddress] if member.fetch('elasticsearch', nil).nil?

      interface = member[:elasticsearch][:interface]
      member.network.interfaces[interface].addresses.select do |_, conf|
        conf[:family] == 'inet'
      end.keys.first
    end

    # @return [String] Command used to extract installation
    def cmd_decompress
      "tar -C #{current.home_dir} -xf #{installer_target} --strip-components 1"
    end

    # Recusively set installation permissions
    # @return [String] Command used to set install permissions
    def cmd_permissions
      "chown -R #{current.user}:#{current.group} #{current.home_dir}"
    end

    # Hash keyed with resource parameters.
    # @return [Hash] Hash providing necessary command, guard & expected return value.
    def cmd_reload_sysctl
      {
        command: "/sbin/sysctl -p /etc/sysctl.d/99-#{current.service_name}.conf",
        expects: [0, 255],
        guard:   "[ $(/sbin/sysctl -n vm.max_map_count) == #{current.resources.memory.map} ]"
      }
    end

    # Returns the size allocated for heap
    # @return [Fixum] Heap size allocated in megabytes
    def java_heap_size
      return current.java_heap if current.java_heap

      case node[:platform_family]
        when 'rhel'    then (0.5 * node[:memory][:total].to_f).to_i / 1024
        when 'smartos' then (0.5 * node[:memory][:total].to_f).to_i
      end
    end

    # Returns Java home directory
    # @return [String] Java home directory
    def java_home
      case node[:platform_family]
        when 'rhel'    then '/usr'
        when 'smartos' then '/opt/local'
      end
    end

    # Returns distribution specific Java package name
    # @return [String] Java package name
    def java_package
      version = current.java_version

      case node[:platform_family]
        when 'rhel'    then "java-#{version}-openjdk-headless"
        when 'smartos' then "openjdk#{version.split('.')[1]}"
      end
    end

    # Provides path to installation archive
    # @returns [String] Absolute path to installation archive
    def installer_target
      return current.source unless current.source.match('^http')

      directory = Chef::Config[:file_cache_path]
      filename  = ::File.basename(current.source)

      ::File.join(directory, filename)
    end

    # Returns a boolean describing the manifest state
    # @return [FalseClass, TrueClass] Manifest state
    def manifest_exists?
      response = shell_out("/usr/bin/svcs -a elasticsearch", returns: '0,1')
      response.exitstatus > 0 ? false : true
    end

    # Command used to delete service manifest
    def manifest_delete
      "/usr/sbin/svccfg delete -f #{current.service_name}"
    end

    # Command used to import service manifest
    def manifest_import
      "/usr/sbin/svccfg import #{service_file}"
    end

    # Returns the absolute path to the service file
    # @return [String] Path to service definition
    def service_file
      case node[:platform_family]
      when 'rhel'
        release  = node[:platform_version].to_i
        systemd  = '/etc/systemd/system/elasticsearch.service'
        sysvinit = '/etc/rc.d/init.d/elasticsearch'

        release >= 7 ? systemd : sysvinit
      when 'smartos'
        ::File.join(Chef::Config[:file_cache_path], 'elasticsearch')
      end
    end
  end
end
