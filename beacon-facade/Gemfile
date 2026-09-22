source 'https://rubygems.org'

gem 'sinatra', '~> 4.0'
gem 'puma', '~> 6.0'
gem 'rackup'
gem 'json'
# Unused by this app -- pinned purely to get a patched version into the Bundler-managed path;
# see the Dockerfile comment for why the base image's own stale default-gem copy still needs
# removing separately. Same pin as Severance's external/internal/shallot-facade Gemfiles.
gem 'net-imap', '~> 0.5'
gem 'erb', '6.0.7'
gem 'resolv', '0.8.0'

group :test do
  gem 'rspec'
  gem 'rack-test'
end
