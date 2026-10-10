require "resolv"

# The Paperless URL is entered by a user and requested from Sure's server, so it
# must not become a way to reach internal services (SSRF). Self-hosted installs
# usually run Paperless on the same network, so private addresses are allowed
# there by default; managed installs block them unless the operator opts in with
# PAPERLESS_ALLOW_PRIVATE_HOSTS=true. Even then, callers decide per connection
# whether private addresses apply (see PaperlessConnection#private_hosts_allowed?).
class Provider::Paperless::HostGuard
  class BlockedHost < StandardError
    attr_reader :reason, :kind

    def initialize(kind)
      @kind = kind
      @reason = I18n.t("paperless.host_guard.#{kind}")
      super(@reason)
    end

    # Blocked only because private addresses were not allowed for this request.
    def private_network?
      kind.in?(%i[https_required private_address])
    end
  end

  # Non-public IPv4 ranges that IPAddr#private?, #loopback? and #link_local? miss.
  BLOCKED_IPV4_RANGES = %w[0.0.0.0/8 100.64.0.0/10 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4].map { |range| IPAddr.new(range) }.freeze
  IPV6_MULTICAST = IPAddr.new("ff00::/8").freeze
  NAT64_PREFIX = IPAddr.new("64:ff9b::/96").freeze

  class << self
    # Returns the checked IP address the request must connect to. It is pinned
    # for private hosts too, so the token never follows a later DNS change.
    def check!(url, allow_private: private_hosts_allowed?)
      uri = parse(url)

      # The API token travels in a header, so a public server must be reached over TLS.
      raise BlockedHost.new(:https_required) unless allow_private || uri.scheme == "https"

      addresses = resolve(uri.host)
      raise BlockedHost.new(:unresolvable) if addresses.empty?
      raise BlockedHost.new(:private_address) if !allow_private && addresses.any? { |ip| internal?(ip) }

      addresses.first.to_s
    end

    def private_hosts_allowed?
      configured = ENV["PAPERLESS_ALLOW_PRIVATE_HOSTS"]
      return ActiveModel::Type::Boolean.new.cast(configured) if configured.present?

      Rails.application.config.app_mode.self_hosted?
    end

    private
      def parse(url)
        uri = URI.parse(url.to_s)
        raise BlockedHost.new(:invalid_url) unless uri.is_a?(URI::HTTP) && uri.host.present?
        raise BlockedHost.new(:credentials_in_url) if uri.userinfo.present?

        uri
      rescue URI::InvalidURIError
        raise BlockedHost.new(:invalid_url)
      end

      def resolve(host)
        literal = IPAddr.new(host.delete_prefix("[").delete_suffix("]")) rescue nil
        return [ literal ] if literal

        Resolv.getaddresses(host).filter_map { |address| IPAddr.new(address) rescue nil }
      end

      def internal?(ip)
        ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
        # A NAT64 address carries an IPv4 address in its last 32 bits; judge that one.
        ip = IPAddr.new(ip.to_i & 0xffffffff, Socket::AF_INET) if ip.ipv6? && NAT64_PREFIX.include?(ip)
        ip.loopback? || ip.private? || ip.link_local? || reserved?(ip)
      end

      def reserved?(ip)
        return true if ip.to_i.zero?

        ip.ipv4? ? BLOCKED_IPV4_RANGES.any? { |range| range.include?(ip) } : IPV6_MULTICAST.include?(ip)
      end
  end
end
