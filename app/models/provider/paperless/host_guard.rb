require "resolv"

# The Paperless URL is entered by a user and requested from Sure's server, so it
# must not become a way to reach internal services (SSRF). Self-hosted installs
# usually run Paperless on the same network, so private addresses are allowed
# there by default; managed installs block them unless the operator opts in with
# PAPERLESS_ALLOW_PRIVATE_HOSTS=true.
class Provider::Paperless::HostGuard
  class BlockedHost < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  class << self
    # Returns the checked IP address the request must connect to, or nil when
    # private hosts are allowed and no check is needed.
    def check!(url)
      uri = parse(url)
      return if private_hosts_allowed?

      addresses = resolve(uri.host)
      raise BlockedHost.new(I18n.t("paperless.host_guard.unresolvable")) if addresses.empty?
      raise BlockedHost.new(I18n.t("paperless.host_guard.private_address")) if addresses.any? { |ip| internal?(ip) }

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
        raise BlockedHost.new(I18n.t("paperless.host_guard.invalid_url")) unless uri.is_a?(URI::HTTP) && uri.host.present?
        raise BlockedHost.new(I18n.t("paperless.host_guard.credentials_in_url")) if uri.userinfo.present?

        uri
      rescue URI::InvalidURIError
        raise BlockedHost.new(I18n.t("paperless.host_guard.invalid_url"))
      end

      def resolve(host)
        literal = IPAddr.new(host.delete_prefix("[").delete_suffix("]")) rescue nil
        return [ literal ] if literal

        Resolv.getaddresses(host).filter_map { |address| IPAddr.new(address) rescue nil }
      end

      def internal?(ip)
        ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
        ip.loopback? || ip.private? || ip.link_local? || unspecified?(ip)
      end

      def unspecified?(ip)
        ip.to_i.zero? || (ip.ipv4? && IPAddr.new("0.0.0.0/8").include?(ip)) ||
          (ip.ipv4? && IPAddr.new("100.64.0.0/10").include?(ip))
      end
  end
end
