# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Runs LinuxNetwork against a fake nmcli that logs its arguments and answers
# like NetworkManager would, so no real network is touched.
class LinuxNetworkTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "nmcli.log")
    @nmcli = File.join(@dir, "nmcli")
    File.write(@nmcli, <<~SH)
      #!/bin/sh
      dir=#{@dir}
      printf '%s\\n' "$*" >> $dir/nmcli.log
      case "$*" in
        "-t -f DEVICE,TYPE device") printf 'eth0:ethernet\\nwlan0:wifi\\n' ;;
        *"ACTIVE,SSID device wifi list ifname wlan0 --rescan no") printf 'no:Voisins\\nyes:Home\\\\:Net\\n' ;;
        *"SSID device wifi list ifname wlan0 --rescan auto") printf 'Home\\\\:Net\\n\\nMERLIN_ABC\\nMERLIN_ABC\\n' ;;
        "-g IP4.ADDRESS device show wlan0") [ -e $dir/offline ] && exit 10; printf '192.168.4.2/24 | 10.1.0.2/16\\n' ;;
        "-t -f NAME,UUID,TYPE,TIMESTAMP connection show")
          printf 'Old:uuid-old:802-11-wireless:100\\nHome profile:uuid-home:802-11-wireless:200\\nWired:uuid-eth:802-3-ethernet:300\\n'
          [ -e $dir/profile ] && printf 'merlin-speaker:uuid-merlin:802-11-wireless:900\\n' ;;
        "-g 802-11-wireless.ssid connection show uuid uuid-home") printf 'Home\\\\:Net\\n' ;;
        "-g 802-11-wireless.ssid connection show uuid uuid-old") printf 'Old\\n' ;;
        "connection add"*) touch $dir/profile ;;
        "connection delete id merlin-speaker") rm $dir/profile ;;
        *"connection up id merlin-speaker"*)
          [ -e $dir/no_speaker ] && { echo "Error: Connection activation failed: No network with SSID found."; exit 4; }
          for a; do last=$a; done
          case "$*" in *passwd-file*) ls -l "$last" | cut -c1-10 > $dir/psk.mode; cat "$last" > $dir/psk ;; esac ;;
      esac
      exit 0
    SH
    File.chmod(0o755, @nmcli)
    @net = Merlin::LinuxNetwork.new(nmcli: @nmcli, user: "alice")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  def test_reads_the_wifi_state_and_unescapes_names
    assert_equal "wlan0", @net.interface
    assert_equal "Home:Net", @net.current_ssid
    assert_equal ["Home:Net", "MERLIN_ABC"], @net.visible_ssids
    assert_equal "192.168.4.2", @net.ip
  end

  def test_ip_is_nil_when_not_connected
    File.write(File.join(@dir, "offline"), "")
    assert_nil @net.ip
  end

  def test_joins_the_speaker_through_an_isolated_profile_without_exposing_the_password
    @net.join("MERLIN_ABC", "s3cr:et pass")
    add = calls.find { _1.start_with?("connection add") }
    %w[ssid\ MERLIN_ABC connection.autoconnect\ no connection.permissions\ user:alice ipv4.never-default\ yes
       ipv4.ignore-auto-dns\ yes ipv6.method\ disabled connection.mdns\ no connection.llmnr\ no
       wifi-sec.psk-flags\ 2].each { assert_includes add, _1 }
    refute calls.any? { _1.include?("s3cr") }, "the password must never be on nmcli's command line"
    assert_equal "802-11-wireless-security.psk:s3cr:et pass\n", File.read(File.join(@dir, "psk"))
    assert_equal "-rw-------", File.read(File.join(@dir, "psk.mode")).strip
    assert_empty Dir.glob(File.join(Dir.tmpdir, "merlin-psk*")).select { File.read(_1).include?("s3cr") rescue false }
  end

  def test_rejoining_recreates_the_profile
    @net.join("MERLIN_ABC", "pw")
    @net.join("MERLIN_XYZ", "pw")
    assert_equal 1, calls.count("connection delete id merlin-speaker")
    assert_equal 2, calls.count { _1.start_with?("connection add") }
  end

  def test_speaker_not_found_raises_a_merlin_error
    File.write(File.join(@dir, "no_speaker"), "")
    err = assert_raises(Merlin::Error) { @net.join("MERLIN_ABC", "pw") }
    assert_match(/No network with SSID found/, err.message)
  end

  def test_home_network_is_rejoined_by_its_saved_profile
    @net.join("Home:Net")
    assert_includes calls, "--wait 15 connection up uuid uuid-home"
  end

  def test_unknown_home_network_falls_back_to_a_plain_connect
    @net.join("Elsewhere")
    assert_includes calls, "--wait 15 device wifi connect Elsewhere ifname wlan0"
  end

  def test_forget_deletes_only_the_speaker_profile
    @net.forget("MERLIN_ABC")
    refute_includes calls, "connection delete id merlin-speaker"
    @net.join("MERLIN_ABC", "pw")
    @net.forget("MERLIN_ABC")
    assert_includes calls, "connection delete id merlin-speaker"
  end

  def test_missing_nmcli_is_a_merlin_error
    net = Merlin::LinuxNetwork.new(nmcli: File.join(@dir, "missing"), user: "alice")
    err = assert_raises(Merlin::Error) { net.interface }
    assert_match(/NetworkManager is needed/, err.message)
  end
end
