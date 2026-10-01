# Create OAuth applications for Sure's first-party apps
# These are the only OAuth apps that will exist - external developers use API keys

# Sure Mobile App (shared across iOS and Android)
# Resolved through MobileDevice so the seed matches on name and redirect URI
# like the app does, and never picks up a same-named client registered by
# someone else.
mobile_app = MobileDevice.shared_oauth_application

puts "Created OAuth applications:"
puts "Mobile App - Client ID: #{mobile_app.uid}"
puts ""
puts "External developers should use API keys instead of OAuth."
