# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def test_linux_uses_networkmanager_and_nftables
    config = Merlin::Config.new(Dir.tmpdir, linux: true)
    assert_instance_of Merlin::LinuxNetwork, config.network
    assert_instance_of Merlin::NftIsolation, config.isolation
  end

  def test_macos_uses_networksetup_and_pf
    config = Merlin::Config.new(Dir.tmpdir, linux: false)
    assert_instance_of Merlin::MacNetwork, config.network
    assert_instance_of Merlin::Isolation, config.isolation
  end
end
