require 'omniauth/strategies/oauth2'
require 'omniauth/facebook/signed_request'
require 'openssl'
require 'rack/utils'
require 'uri'

module OmniAuth
  module Strategies
    class Facebook < OmniAuth::Strategies::OAuth2
      class NoAuthorizationCodeError < StandardError; end
      class MissingScopesError < StandardError; end
      class AppIdMismatchError < StandardError; end

      DEFAULT_SCOPE = 'email'

      option :client_options, {
        site: 'https://graph.facebook.com/v2.10',
        authorize_url: "https://www.facebook.com/v2.10/dialog/oauth",
        token_url: 'oauth/access_token'
      }

      option :access_token_options, {
        header_format: 'OAuth %s',
        param_name: 'access_token'
      }

      option :authorize_options, [:scope, :display, :auth_type]

      uid { raw_info['id'] }

      info do
        prune!({
          'nickname' => raw_info['username'],
          'email' => raw_info['email'],
          'name' => raw_info['name'],
          'first_name' => raw_info['first_name'],
          'last_name' => raw_info['last_name'],
          'image' => image_url(uid, options),
          'description' => raw_info['bio'],
          'urls' => {
            'Facebook' => raw_info['link'],
            'Website' => raw_info['website']
          },
          'location' => (raw_info['location'] || {})['name'],
          'verified' => raw_info['verified']
        })
      end

      extra do
        hash = {}
        hash['raw_info'] = raw_info unless skip_info?
        prune! hash
      end

      def raw_info
        @raw_info ||= access_token.get('me', info_options).parsed || {}
      end

      def info_options
        params = {appsecret_proof: appsecret_proof}
        params.merge!({fields: (options[:info_fields] || 'name,email')})
        params.merge!({locale: options[:locale]}) if options[:locale]

        { params: params }
      end

      def callback_phase
        with_authorization_parameter! do
          super
        end
      rescue AppIdMismatchError => e
        fail!(:app_id_mismatch, e)
      rescue MissingScopesError => e
        fail!(:missing_scopes, e)
      rescue NoAuthorizationCodeError => e
        fail!(:no_authorization_code, e)
      rescue OmniAuth::Facebook::SignedRequest::UnknownSignatureAlgorithmError => e
        fail!(:unknown_signature_algorithm, e)
      end

      # NOTE If we're using code from the signed request then FB sets the redirect_uri to '' during the authorize
      #      phase and it must match during the access_token phase:
      #      https://github.com/facebook/facebook-php-sdk/blob/master/src/base_facebook.php#L477
      def callback_url
        if defined?(@auth_code_from_cookie) && @auth_code_from_cookie
          ''
        else
          # Fixes regression in omniauth-oauth2 v1.4.0 by https://github.com/intridea/omniauth-oauth2/commit/85fdbe117c2a4400d001a6368cc359d88f40abc7
          options[:callback_url] || (full_host + script_name + callback_path)
        end
      end

      def access_token_options
        options.access_token_options.inject({}) { |h,(k,v)| h[k.to_sym] = v; h }
      end

      # You can pass +display+, +scope+, or +auth_type+ params to the auth request, if you need to set them dynamically.
      # You can also set these options in the OmniAuth config :authorize_params option.
      #
      # For example: /auth/facebook?display=popup
      def authorize_params
        super.tap do |params|
          %w[display scope auth_type].each do |v|
            if request.params[v]
              params[v.to_sym] = request.params[v]
            end
          end

          params[:scope] ||= DEFAULT_SCOPE
        end
      end

      protected

      def build_access_token
        if request.params["access_token"]
          build_access_token_from_request(request.params["access_token"])
        else
          super.tap do |token|
            token.options.merge!(access_token_options)
          end
        end
      end

      private

      def build_access_token_from_request(access_token_param)
        token_hash = { :access_token => access_token_param }
        access_token = ::OAuth2::AccessToken.from_hash(client, token_hash.update(access_token_options))
        verify_access_token!(access_token)
        return access_token
      end

      def verify_access_token!(access_token)
        opts = { params: { input_token: access_token.token, access_token: app_access_token }}
        token_info = access_token.get('/debug_token', opts)
        missing_scopes = authorize_params.scope.split(',').collect(&:strip) - token_info.parsed.fetch("data", {}).fetch("scopes", [])
        raise MissingScopesError, "Missing scopes #{missing_scopes.join(', ')}" if missing_scopes.any?
      rescue ::OAuth2::Error => e
        raise AppIdMismatchError, "Failed to validate token: #{e.message}"
      end

      def app_access_token
        "%s|%s" % [client.id, client.secret]
      end

      # Picks the authorization code in order, from:
      #
      # 1. The request 'code' param (manual callback from standard server-side flow)
      # 2. A signed request from cookie (passed from the client during the client-side flow)
      def with_authorization_parameter!
        if request.params.key?('code') || request.params.key?('access_token')
          yield
        elsif code_from_signed_request = signed_request_from_cookie && signed_request_from_cookie['code']
          request.params['code'] = code_from_signed_request
          @auth_code_from_cookie = true
          # NOTE The code from the signed fbsr_XXX cookie is set by the FB JS SDK will confirm that the identity of the
          #      user contained in the signed request matches the user loading the app.
          original_provider_ignores_state = options.provider_ignores_state
          options.provider_ignores_state = true
          begin
            yield
          ensure
            request.params.delete('code')
            @auth_code_from_cookie = false
            options.provider_ignores_state = original_provider_ignores_state
          end
        else
          raise NoAuthorizationCodeError, 'must pass either a `access_token` param or a `code` (via URL param or by an `fbsr_XXX` signed request cookie)'
        end
      end

      def signed_request_from_cookie
        @signed_request_from_cookie ||= raw_signed_request_from_cookie && OmniAuth::Facebook::SignedRequest.parse(raw_signed_request_from_cookie, client.secret)
      end

      def raw_signed_request_from_cookie
        request.cookies["fbsr_#{client.id}"]
      end

      def prune!(hash)
        hash.delete_if do |_, value|
          prune!(value) if value.is_a?(Hash)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def image_url(uid, options)
        uri_class = options[:secure_image_url] ? URI::HTTPS : URI::HTTP
        site_uri = URI.parse(client.site)
        url = uri_class.build({host: site_uri.host, path: "#{site_uri.path}/#{uid}/picture"})

        query = if options[:image_size].is_a?(String) || options[:image_size].is_a?(Symbol)
          { type: options[:image_size] }
        elsif options[:image_size].is_a?(Hash)
          options[:image_size]
        end
        url.query = Rack::Utils.build_query(query) if query

        url.to_s
      end

      def appsecret_proof
        @appsecret_proof ||= OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, client.secret, access_token.token)
      end
    end
  end
end