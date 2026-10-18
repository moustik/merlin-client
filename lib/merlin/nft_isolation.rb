# frozen_string_literal: true

module Merlin
  # Isolation for Linux: the same three rules as the pf version, as an
  # nftables table, applied and removed by the same one-password root helper.
  #
  # On Linux the speaker profile already keeps the speaker from becoming the
  # gateway or DNS server (see LinuxNetwork); this filter also stops what that
  # doesn't cover, such as broadcasts on the speaker's subnet.
  class NftIsolation < Isolation
    TABLE = "inet merlin"

    # $1 = rules, $2 = nft path. Each script starts by declaring then deleting
    # the table, so loading is atomic and "on"/"off" are safe to repeat.
    HELPER = <<~'SH'
      rules=$1; nft=$2
      echo __READY__
      while IFS= read -r cmd; do
        case "$cmd" in
          on)
            if printf '%s' "$rules" | "$nft" -f - 2>&1
            then echo __OK__; else echo __FAIL__; fi ;;
          off*)
            if printf 'table inet merlin\ndelete table inet merlin\n' | "$nft" -f - 2>&1
            then echo __OK__; else echo __FAIL__; fi ;;
          quit) exit 0 ;;
          *) echo "unknown command"; echo __FAIL__ ;;
        esac
      done
    SH

    def initialize(nft: "/usr/bin/nft", network: nil, **opts)
      super(pfctl: nft, **opts)
      @network = network
    end

    def rules
      iface = interface
      <<~NFT
        table #{TABLE}
        delete table #{TABLE}
        table #{TABLE} {
          chain out {
            type filter hook output priority 0; policy accept;
            oifname "#{iface}" ip daddr #{@speaker_ip} tcp dport #{@port} accept
            oifname "#{iface}" udp sport 68 udp dport 67 accept
            oifname "#{iface}" ip saddr #{@subnet} drop
          }
        }
      NFT
    end

    private

    def tool_name = "nft"
    def interface = @interface ||= (@network || LinuxNetwork.new).interface
  end
end
