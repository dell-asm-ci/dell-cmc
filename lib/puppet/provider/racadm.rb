class Puppet::Provider::Racadm <  Puppet::Provider

  def role_permissions
    {"Administrator" => "0x00000fff", "PowerUser" => "0x00000ed9", "GuestUser" => "0x00000001", "None" => "0x00000000"}
  end

  def enabled_bit(value)
    (value == true || value == "Enabled") ? "1" : "0"
  end

  def connection
    @device ||= Puppet::Util::NetworkDevice.current
    raise Puppet::Error, "Puppet::Util::NetworkDevice::Cmc: device not initialized #{caller.join("\n")}" unless @device
    @device.transport
  end

  def racadm_cmd(subcommand, flags={}, params='', verbose=true)
    cmd = "racadm #{subcommand}"
    if(!params.empty?)
      param_string = params.is_a?(Array) ? params.join(" ") : " #{params}"
      cmd << param_string
    end
    append_flags(cmd, flags)
    output = connection.command(cmd)
    munged_output = parse_output_values(output)
    Puppet.info("racadm #{subcommand} result: #{munged_output}") if verbose
    return munged_output
  end

  def racadm_set_config(group, config_object, param_values, flags={})
    param_string = param_values.is_a?(Array) ? param_values.join(" ") : param_values
    cmd = "racadm config -g #{group} -o #{config_object} #{param_string}"
    append_flags(cmd, flags)
    output = connection.command(cmd)
    munged_output = parse_output_values(output)
    Puppet.info("racadm_set_config  for group #{group} and object #{config_object} result: #{munged_output}")
    munged_output
  end

  def racadm_get_config(group=nil, config_object=nil, flags={})
    cmd = "racadm getconfig"
    if(group)
      cmd << " -g #{group}"
    end
    if(config_object)
      cmd << " -o #{config_object}"
    end
    append_flags(cmd, flags)
    output = connection.command(cmd)
    parse_output_values(output)
  end

  def racadm_set_niccfg(module_name, type, ip_addr=nil, ip_mask=nil, gateway=nil)
    cmd = "racadm setniccfg -m #{module_name}"
    network_settings = ""
    if(type == :dhcp)
      network_settings = ' -d'
    elsif(type == :static)
      network_settings = " -s #{ip_addr} #{ip_mask} #{gateway}"
    end
    cmd << network_settings
    output = connection.command(cmd)
    munged_output = parse_output_values(output)
    Puppet.info("racadm_set_niccfg result for #{module_name}: #{munged_output}")
    munged_output
  end

  def racadm_set_user(name, password, role, enabled, index)
    permission_bits = role_permissions[role]
    name_result = racadm_set_config('cfgUserAdmin', 'cfgUserAdminUserName', name, {'i' => index})
    Puppet.err("Could not set username for user at index #{index}") unless name_result.to_s =~ /successfully/
    password_result = racadm_set_config('cfgUserAdmin', 'cfgUserAdminPassword', password, {'i' => index})
    Puppet.err("Could not set password for user at index #{index}") unless password_result.to_s =~ /successfully/
    role_result = racadm_set_config('cfgUserAdmin', 'cfgUserAdminPrivilege', permission_bits, {'i' => index})
    Puppet.err("Could not set privileges for user at index  #{index}") unless role_result.to_s =~ /successfully/
    enabled_bit = enabled ? 1 : 0
    enable_result = racadm_set_config('cfgUserAdmin', 'cfgUserAdminEnable', enabled_bit, {'i' => index})
    Puppet.err("Could not enable user #{index} at index") unless enable_result.to_s =~ /successfully/
  end

  def racadm_set_root_creds(password, type, slot, smnp_string=nil)
    flags = {
      'u' => 'root',
      'p' => "'#{password}'",
      'm' => "#{type}-#{slot}"
    }
    if !smnp_string.nil?
      flags['v'] = ['SNMPv2', smnp_string, 'ro'].join(' ')
    end
    output = racadm_cmd('deploy', flags, '', false)
    Puppet.info("racadm_set_creds result for #{type}-#{slot}: #{output}")
    output
  end

  def get_password(credential)
    return credential
  end
  
  #This method is only used for extending this provider, in order to add custom decryption to the community string field if desired.
  def get_community_string(string)
    string
  end

  def set_networks(module_type, network_type, networks)
    slots_to_check = {}
    errored = {}
    networks.each do |slot, network|
      result = set_network("#{module_type}-#{slot}", network, network_type)
      if result =~ /ERROR/
        errored[slot] = network
      else
        slots_to_check[slot] = network
      end
    end
    # Sometimes setting the addressing does not work when reset to factory defaults, so we want to retry a few times.
    # Trying to set it the first time seems to trigger it to be in a better state a minute or 2 later.
    errored.each do |slot, network|
      attempts ||= 0
      Puppet.debug("Could not set #{network_type} network for #{module_type}-#{slot}.  Retrying in 30 seconds...")
      sleep 30
      if (attempts += 1) < 6
        result = set_network("#{module_type}-#{slot}", network, network_type)
        if result =~ /ERROR/
          redo
        else
          slots_to_check[slot] = network
        end
      else
        Puppet.error("Networking cannot be set for #{module_type}-#{slot}.")
      end
    end

    if(network_type == :dhcp)
      wait_for_dhcp(module_type, slots_to_check)
    else
      wait_for_static(module_type, slots_to_check)
    end
  end

  def set_network(module_name, network, network_type)
    if(network_type == :dhcp)
      output = racadm_set_niccfg(module_name, network_type)
    elsif(network_type == :static)
      network_obj = network['staticNetworkConfiguration']
      output = racadm_set_niccfg(module_name, network_type, network_obj['ipAddress'], network_obj['subnet'], network_obj['gateway'])
    end
    output
  end


  def wait_for_dhcp(module_type, slots_to_check)
    slots_to_check.each do |slot, value|
      checks = 1
      ip_address = ''
      #The wait should be pretty short if at all for the slots other than the first one checked
      name = "#{module_type}-#{slot}"
      loop do
        output = racadm_cmd('getniccfg', {'m' => "#{name}"})
        ip_address = output['IP Address']
        break if checks > 10 || (output['DHCP Enabled'] == '1' && ip_address != '0.0.0.0')
        checks += 1
        sleep 30
        Puppet.info("Waiting for DHCP address for #{name}")
      end
      if checks == 10
        raise "Timed out waiting for DHCP address for #{name}"
      else
        wait_for_connectivity(ip_address, name)
      end
    end
  end

  def wait_for_static(module_type, slots_to_check)
    slots_to_check.each do |slot, value|
      checks = 1
      ip_address = ''
      name = "#{module_type}-#{slot}"
      loop do
        output = racadm_cmd('getniccfg', {'m' => "#{name}"})
        ip_address = output['IP Address']
        break if checks > 10 || (ip_address == value['staticNetworkConfiguration']['ipAddress'])
        checks += 1
        sleep 30
        Puppet.info("Waiting for Static address for #{name}")
      end
      if checks > 10
        raise "Timed out waiting for Static address for #{name}"
      else
        wait_for_connectivity(ip_address, name)
      end
    end
  end

  def wait_for_connectivity(ip_address, name)
    checks = 1
    loop do
      Puppet.info("Waiting for connectivity to #{name} at #{ip_address}...")
      output = racadm_cmd('ping', {}, ip_address)
      break if checks > 10 || output.find{|line| line =~ /1 packets received/}
      checks += 1
      sleep 15
    end
    if checks > 10
      raise "Could not ping #{ip_address}"
    else
      Puppet.info("#{name} is now reachable at #{ip_address}")
    end

  end

  def append_flags(cmd, flag_hash)
    flag_hash.keys.each do |flag|
      cmd << " -#{flag} #{flag_hash[flag]}"
    end
    cmd
  end

  def parse_output_values(output)
    if(output.nil?)
      return ''
    end
    lines = output.split("\n")
    #First line contain the command sent through, which we don't want to show in logs.
    lines.shift
    #Last line contains the command prompt after the command has run.
    lines.pop
    if(lines.empty?)
      return ''
    end
    #If we can split by =, it's a return with key/values we can parse.  Otherwise, just return the output as is split by new line character
    if(lines.first.split("=").size > 1)
      Hash[lines.map{|str| str.split("=")}.collect{|line|
        key = line[0].strip
        #Sometimes, the first line starts with # symbol.  Just clean it out if it does so we return a good hash
        if(key.start_with?('#'))
          key = key[1..-1].strip
        end
        value = line[1].nil? ? "" : line[1].strip 
        [key, value]
        }]
    elsif(lines.size == 1)
      lines.first
    else
      lines
    end
  end
end
