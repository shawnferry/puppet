require 'puppet/provider/package'

Puppet::Type.type(:package).provide :pkg, :parent => Puppet::Provider::Package do
  desc "Solaris image packaging system. See pkg(5) for more information"
  # https://docs.oracle.com/cd/E19963-01/html/820-6572/managepkgs.html
  # A few notes before we start:
  # Opensolaris pkg has two slightly different formats (as of now.)
  # The first one is what is distributed with the Solaris 11 Express 11/10 dvd
  # The latest one is what you get when you update package.
  # To make things more interesting, pkg version just returns a sha sum.
  # dvd:     pkg version => 052adf36c3f4
  # updated: pkg version => 630e1ffc7a19
  # Thankfully, Solaris has not changed the commands to be used.
  # TODO: We still have to allow packages to specify a preferred publisher.

  has_feature :versionable
  has_feature :upgradable
  has_feature :holdable
  has_feature :install_options
  has_feature :uninstall_options

  commands :pkg => "/usr/bin/pkg"

  confine :osfamily => :solaris

  defaultfor :osfamily => :solaris, :kernelrelease => ['5.11', '5.12']

  def self.instances
    pkg(:list, '-Hv').split("\n").map{|l| new(parse_line(l))}
  end

  # The IFO flag field is just what it names, the first field can have either
  # i_nstalled or -, and second field f_rozen or -, and last
  # o_bsolate or r_rename or -
  # so this checks if the installed field is present, and also verifies that
  # if not the field is -, else we don't know what we are doing and exit with
  # out doing more damage.
  def self.ifo_flag(flags)
    (
      case flags[0..0]
      when 'i'
        {:status => 'installed'}
      when '-'
        {:status => 'known'}
      else
        raise ArgumentError, 'Unknown format %s: %s[%s]' % [self.name, flags, flags[0..0]]
      end
    ).merge(
      case flags[1..1]
      when 'f'
        {:ensure => 'held'}
      when '-'
        {}
      else
        raise ArgumentError, 'Unknown format %s: %s[%s]' % [self.name, flags, flags[1..1]]
      end
    )
  end

  # The UFOXI field is the field present in the older pkg
  # (solaris 2009.06 - snv151a)
  # similar to IFO, UFOXI is also an either letter or -
  # u_pdate indicates that an update for the package is available.
  # f_rozen(n/i) o_bsolete x_cluded(n/i) i_constrained(n/i)
  # note that u_pdate flag may not be trustable due to constraints.
  # so we dont rely on it
  # Frozen was never implemented in UFOXI so skipping frozen here.
  def self.ufoxi_flag(flags)
    {}
  end

  def self.ufxi_flag(flags)
    {}
  end

  # pkg state was present in the older version of pkg (with UFOXI) but is
  # no longer available with the IFO field version. When it was present,
  # it was used to indicate that a particular version was present (installed)
  # and later versions were known. Note that according to the pkg man page,
  # known never lists older versions of the package. So we can rely on this
  # field to make sure that if a known is present, then the pkg is upgradable.
  def self.pkg_state(state)
    case state
    when /installed/
      {:status => 'installed'}
    when /known/
      {:status => 'known'}
    else
      raise ArgumentError, 'Unknown format %s: %s' % [self.name, state]
    end
  end

  # Here is (hopefully) the only place we will have to deal with multiple
  # formats of output for different pkg versions.
  def self.parse_line(line)
    (case line.chomp
    # FMRI                                                                         IFO
    # pkg://omnios/SUNWcs@0.5.11,5.11-0.151008:20131204T022241Z                    ---
    when %r'^pkg://([^/]+)/([^@]+)@(\S+) +(...)$'
      {:publisher => $1, :name => $2, :ensure => $3}.merge ifo_flag($4)

    # FMRI                                                             STATE      UFOXI
    # pkg://solaris/SUNWcs@0.5.11,5.11-0.151.0.1:20101105T001108Z      installed  u----
    when %r'^pkg://([^/]+)/([^@]+)@(\S+) +(\S+) +(.....)$'
      {:publisher => $1, :name => $2, :ensure => $3}.merge pkg_state($4).merge(ufoxi_flag($5))

    #pkg list -vH output format since build 165
    #FMRI                                                                         IFO
    #pkg://solaris/system/core-os@5.12-5.12.0.0.0.87.1:20151116T010109Z           i--
    when /^(\S+) +(...)$/
      full_fmri = $1.split('@')
      {:name => full_fmri[0], :ensure => full_fmri[1]}.merge(ifo_flag($2))

    #Solaris11 Express 10/11, OpenSolaris
    #FMRI                                                               STATE       UFOXI
    #pkg://solaris/editor/vim@7.2.308,5.11-0.151.0.1:20101105T0540492   installed   -----
    when /^(\S+) +(\S+) +(.....)$/
      full_fmri = $1.split('@')
      {:name => full_fmri[0], :ensure => full_fmri[1]}.merge pkg_state($2).merge(ufoxi_flag($3))

    #OpenSolaris
    #FMRI                                               STATE       UFXI
    #pkg:/SUNWvim@7.1.145,5.11-0.86:20080426T180612Z    installed   ----
    when /^(\S+) +(\S+) +(....)$/
      full_fmri = $1.split('@')
      {:name => full_fmri[0], :ensure => full_fmri[1]}.merge pkg_state($2).merge(ufxi_flag($3))

    else
      raise ArgumentError, 'Unknown line format %s: %s' % [self.name, line]
    end).merge({:provider => self.name})
  end

  def parse_latest_query(exit_code, pkg_fmri_list)
    # Get the current status of the package
    name = @property_hash[:name]
    provider = @property_hash[:provider]

    # The package is up-to-date
    if pkg_fmri_list.empty? && exit_code == 4
      status = 'installed'
      version = @property_hash[:ensure]
    # Latest version is available
    elsif !pkg_fmri_list.empty? && exit_code == 0
      if wildcard?
        version = ''
        status = 'known'
      else
        # Search for the correct pkg FMRI (to ignore dependencies)
        # search string format will be, i.e.,
        # pkg://test/testing/testpkg@
        # and retrieve the matched index.
        search_pkg_name = name + '@'
        index = pkg_fmri_list.index{|l| l[0].include?(search_pkg_name)}
        raise Puppet::Error, "Cannot retrieve pkg name" if index.nil?

        # Parse the fmri of the latest available pkg, i.e.,
        # from: pkg://test/testing/testpkg@1.0.13,5.11:20151112T015434Z
        # to: 1.0.13,5.11:20151112T015434Z
        version = pkg_fmri_list[index][1].split('@')[1]
        status = 'known'
      end
    else
      raise Puppet::Error, "Cannot retrieve pkg version"
    end

    # Store as a desirable query
    return {
      :name=>name,
      :ensure=>version,
      :status=>status,
      :provider=>provider
    }
  end

  def hold
    pkg(:freeze, @resource[:name])
  end

  def unhold
    r = exec_cmd(command(:pkg), 'unfreeze', @resource[:name])
    raise Puppet::Error, "Unable to unfreeze #{r[:out]}" unless [0,4].include? r[:exit]
  end

  def insync?(is)
    # this is called after the generic version matching logic (insync? for the
    # type), so we only get here if should != is, and 'should' is a version
    # number. 'is' might not be, though.
    should = @resource[:ensure]
    # NB: it is apparently possible for repository administrators to publish
    # packages which do not include build or branch versions, but component
    # version must always be present, and the timestamp is added by pkgsend
    # publish.
    if /^[0-9.]+(,[0-9.]+)?(-[0-9.]+)?:[0-9]+T[0-9]+Z$/ !~ should
      # We have a less-than-explicit version string, which we must accept for
      # backward compatibility. We can find the real version this would match
      # by asking pkg for the all matching versions, and selecting the first
      # installable one [0]; this can change over time when remote repositories
      # are updated, but the principle of least astonishment should still hold:
      # if we allow users to specify less-than-explicit versions, the
      # functionality should match that of the package manager.
      #
      # [0]: we could simply get the newest matching version with 'pkg list
      # -n', but that isn't always correct, since it might not be installable.
      # If that were the case we could potentially end up returning false for
      # insync? here but not actually changing the package version in install
      # (ie. if the currently installed version is the latest matching version
      # that is installable, we would falsely conclude here that since the
      # installed version is not the latest matching version, we're not in
      # sync).  'pkg list -a' instead of '-n' would solve this, but
      # unfortunately it doesn't consider downgrades 'available' (eg. with
      # installed foo@1.0, list -a foo@0.9 would fail).
      name = @resource[:name]
      potential_matches = pkg(:list, '-Hvfa', "#{name}@#{should}").split("\n").map{|l|self.class.parse_line(l)}
      n = potential_matches.length
      if n > 1
        warning("Implicit version #{should} has #{n} possible matches")
      end
      potential_matches.each{ |p|
        command = is == :absent ? 'install' : 'update'
        status = exec_cmd(command(:pkg), command, '-n', "#{name}@#{p[:ensure]}")[:exit]
        case status
        when 4
          # if the first installable match would cause no changes, we're in sync
          return true
        when 0
          warning("Selecting version '#{p[:ensure]}' for implicit '#{should}'")
          @resource[:ensure] = p[:ensure]
          return false
        end
      }
      raise Puppet::DevError, "No version of #{name} matching #{should} is installable, even though the package is currently installed"
    end

    false
  end

  def latest
    # Dry-run package update to check the availability of the latest version
    # -- return code --
    # 0: latest version available
    # 1: error
    # 4: already up-to-date
    r = exec_cmd(command(:pkg), 'update', '-n', '--parsable=0', @resource[:name]).split('\n')
    package_versions = JSON.parse(r[:out])['change-packages']

    # remove certificate expiration warnings from the output, but report them
    cert_warnings = r[:out].select { |line| line =~ /^Certificate/ }
    unless cert_warnings.empty?
      Puppet.warning("pkg warning: #{cert_warnings.join(', ')}")
    end
    lst = r[:out].select { |line| line !~ /^Certificate/ }.map { |line| self.class.parse_line(line) }

    raise Puppet::Error, "Cannot update to the latest package: #{r[:out]}\n" \
      unless [0, 4].include? r[:exit]

    lst =  parse_latest_query(r[:exit], package_versions)
    Puppet.debug "Desirable query status = #{lst}"
    return lst[:ensure]
  end

  # install the package and accept all licenses.
  def install(nofail = false)
    name = @resource[:name]
    should = @resource[:ensure]
    # always unhold if explicitly told to install/update
    self.unhold
    is = self.query
    if is[:ensure].to_sym == :absent
      command = 'install'
    else
      command = 'update'
    end
    unless should.is_a? Symbol
      name += "@#{should}"
    end

    opts = ['--accept']
    opts << join_options(@resource[:install_options]) if @resource[:install_options]
    r = exec_cmd(command(:pkg), 'install', opts, name)
    return r if nofail
    raise Puppet::Error, "Unable to update #{r[:out]}" if r[:exit] != 0
  end

  # uninstall the package. The complication comes from the -r_ecursive flag which is no longer
  # present in newer package version.
  def uninstall
    cmd = [:uninstall]
    case (pkg :version).chomp
    when /052adf36c3f4/
      cmd << '-r'
    end
    cmd << join_options(@resource[:uninstall_options]) if @resource[:uninstall_options]
    cmd << @resource[:name]
    pkg cmd
  end

  # update the package to the latest version available
  def update
    r = install(true)
    # 4 == /No updates available for this image./
    return if [0,4].include? r[:exit]
    raise Puppet::Error, "Unable to update #{r[:out]}"
  end

  def wildcard?
    @resource[:name].include?("*") || @resource[:name].include?("?")
  end

  # list a specific package
  def query
    r = exec_cmd(command(:pkg), 'list', '-Hv', @resource[:name])
    return {:ensure => :absent, :name => @resource[:name]} if r[:exit] != 0

    # Does input contain wildcard? just pass it down and let pkg decide
    return {:ensure => :installed, :name => @resource[:name], :provider => self.class.name} if wildcard?
    # If there are more than one results? this will fail due to the ambiguity.
    if r[:out].split("\n").length > 1
      raise Puppet::Error, "'#{@resource[:name]}' matches multiple packages. \n#{r[:out]}"
    end
    # Pass the parsed result back to @property_hash
    self.class.parse_line(r[:out])
  end

  def exec_cmd(*cmd)
    output = Puppet::Util::Execution.execute(cmd, :failonfail => false, :combine => true)
    {:out => output, :exit => $CHILD_STATUS.exitstatus}
  end
end
