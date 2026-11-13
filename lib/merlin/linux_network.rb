# frozen_string_literal: true

require "open3"
require "etc"
require "tempfile"

module Merlin
  # The Linux counterpart of MacNetwork, driven by NetworkManager's nmcli.
  #
  # The speaker is joined through a dedicated, user-owned profile that can
  # never become this computer's gateway or DNS server (ipv4.never-default,
  # ipv4.ignore-auto-dns, no IPv6 / mDNS / LLMNR). That is what the Android
  # app gets from bindProcessToNetwork, and it keeps the burst of other apps'
  # traffic that makes the speaker reboot away from it (see Isolation).
  class LinuxNetwork
    PROFILE = "merlin-speaker"
    JOIN_TIMEOUT = 15 # seconds nmcli waits for an activation
    # polkit lets the user of an active local (desktop) session change their
    # own Wi-Fi profiles; over SSH or from a service it asks for auth and fails.
    POLKIT_HINT = " (NetworkManager only lets a local desktop session change Wi-Fi settings: " \
                  "run merlin from your desktop session, or add a polkit rule for your user)"

    def initialize(interface: nil, nmcli: "nmcli", user: Etc.getpwuid.name)
      @interface = interface
      @nmcli = nmcli
      @user = user
    end

    def interface
      @interface ||= terse(run!("-t", "-f", "DEVICE,TYPE", "device")).find { _2 == "wifi" }&.first or
        raise Error, "no Wi-Fi device found by NetworkManager"
    end

    def current_ssid
      terse(wifi_list("ACTIVE,SSID", rescan: "no")).find { |active, _| active == "yes" }&.last.then { _1.to_s.empty? ? nil : _1 }
    end

    def visible_ssids = terse(wifi_list("SSID", rescan: "auto")).map(&:first).reject(&:empty?).uniq

    # nil when not connected (like MacNetwork, which never raises here).
    def ip
      run!("-g", "IP4.ADDRESS", "device", "show", interface).split(" | ").first.to_s[%r{\A[^/\s]+}]
    rescue Error
      nil
    end

    # The machine-wide default route, whichever interface it uses: with the
    # speaker profile it should never be 192.168.4.1.
    def default_gateway
      out, = Open3.capture2("ip", "-4", "route", "show", "default")
      out[/\Adefault via (\S+)/, 1]
    rescue SystemCallError
      nil
    end

    # With a password: the speaker, through its own profile (the password is
    # handed to nmcli in a private file, never on the command line, and isn't
    # stored in the profile). Without: a saved network, found by its SSID.
    def join(ssid, password = nil)
      return join_saved(ssid) if password.nil?

      write_speaker_profile(ssid, password)
      Tempfile.create("merlin-psk") do |file| # created 0600
        file.write("802-11-wireless-security.psk:#{password}\n") unless password.empty?
        file.flush
        run!("--wait", JOIN_TIMEOUT.to_s, "connection", "up", "id", PROFILE, "ifname", interface,
             *(["passwd-file", file.path] unless password.empty?))
      end
    end

    # So the speaker's network is never joined outside a sync.
    def forget(_ssid)
      run!("connection", "delete", "id", PROFILE) if profile_exists?
    rescue Error
      nil
    end

    # Lets NetworkManager auto-join its preferred network (used when the
    # previous network's name couldn't be read or rejoined).
    def power_cycle
      begin
        run!("device", "disconnect", interface)
      rescue Error
        nil # already disconnected
      end
      # Without a saved network nmcli only says "A 'wireless' setting is required…".
      raise Error, "NetworkManager has no saved Wi-Fi network to go back to" if saved_wifi_profiles.all? { _1[:name] == PROFILE }

      sleep 3
      run!("--wait", JOIN_TIMEOUT.to_s, "device", "connect", interface)
    end

    private

    def wifi_list(fields, rescan:) = run!("-t", "-f", fields, "device", "wifi", "list", "ifname", interface, "--rescan", rescan)

    def write_speaker_profile(ssid, password)
      run!("connection", "delete", "id", PROFILE) if profile_exists? # the SSID may have changed
      security = password.empty? ? [] : ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk-flags", "2"] # 2: not saved
      run!("connection", "add", "type", "wifi", "con-name", PROFILE, "ifname", interface, "ssid", ssid, *security,
           "connection.autoconnect", "no", "connection.permissions", "user:#{@user}",
           "ipv4.method", "auto", "ipv4.never-default", "yes", "ipv4.ignore-auto-dns", "yes",
           "ipv6.method", "disabled", "connection.mdns", "no", "connection.llmnr", "no")
    end

    def profile_exists? = saved_wifi_profiles.any? { _1[:name] == PROFILE }

    # Most recently used first, like NetworkManager's own autoconnect choice.
    def join_saved(ssid)
      profile = saved_wifi_profiles.reject { _1[:name] == PROFILE }
                                   .find { profile_ssid(_1[:uuid]) == ssid }
      if profile
        run!("--wait", JOIN_TIMEOUT.to_s, "connection", "up", "uuid", profile[:uuid])
      else
        run!("--wait", JOIN_TIMEOUT.to_s, "device", "wifi", "connect", ssid, "ifname", interface)
      end
    end

    def saved_wifi_profiles
      terse(run!("-t", "-f", "NAME,UUID,TYPE,TIMESTAMP", "connection", "show"))
        .select { _3 == "802-11-wireless" }
        .sort_by { -_4.to_i }
        .map { { name: _1, uuid: _2 } }
    end

    def profile_ssid(uuid) = unescape(run!("-g", "802-11-wireless.ssid", "connection", "show", "uuid", uuid).chomp)

    # nmcli -t output: fields split on ':', with ':' and '\' escaped as '\:' and '\\'.
    def terse(out) = out.lines(chomp: true).map { split_terse(_1) }

    def split_terse(line)
      fields = [+""]
      chars = line.each_char
      loop do
        char = chars.next
        if char == "\\" then fields.last << chars.next
        elsif char == ":" then fields << +""
        else fields.last << char
        end
      end
      fields
    end

    def unescape(field) = field.gsub(/\\(.)/, '\1')

    def run!(*args)
      out, status = Open3.capture2e({ "LC_ALL" => "C" }, @nmcli, *args)
      unless status.success?
        message = out.strip.lines.last.to_s.strip.then { _1.empty? ? "nmcli #{args[0..1].join(' ')} failed" : _1 }
        message += POLKIT_HINT if message.include?("Insufficient privileges")
        raise Error, message
      end

      out
    rescue SystemCallError => e
      raise Error, "can't run nmcli (#{e.message}): NetworkManager is needed on Linux"
    end
  end
end
