#!/usr/bin/env ruby
# frozen_string_literal: true

# Map the consolidated local secrets.yaml inventory to the flat environment
# expected by local-deploy.sh/local-pipeline.sh. CI does NOT use this adapter;
# CI continues to receive GitHub Environment secrets directly.
require "json"
require "yaml"

abort "usage: #{File.basename($PROGRAM_NAME)} SECRETS_YAML OUTPUT_ENV" unless ARGV.length == 2
source, output = ARGV
raw = File.read(source).gsub("\t", "  ")
data = YAML.safe_load(raw, aliases: true)
abort "secrets YAML root must be a mapping" unless data.is_a?(Hash)

def dig!(data, *path)
  value = path.reduce(data) { |node, key| node.is_a?(Hash) ? node[key] : nil }
  abort "missing secrets.yaml key: #{path.join('.')}" if value.nil? || value.to_s.empty?
  value.to_s
end

def dig_optional(data, *path)
  path.reduce(data) { |node, key| node.is_a?(Hash) ? node[key] : nil }.to_s
end

home = ENV.fetch("HOME")
local = data.fetch("local_deploy", {})
firebase = data.fetch("firebase")
admin = firebase.fetch("admin_sdk").dup
admin["project_id"] ||= dig!(data, "firebase", "project_id")
admin["auth_provider_x509_cert_url"] ||= "https://www.googleapis.com/oauth2/v1/certs"
email = admin.fetch("client_email")
admin["client_x509_cert_url"] ||= "https://www.googleapis.com/robot/v1/metadata/x509/#{email.gsub('@', '%40')}"
admin["universe_domain"] ||= "googleapis.com"

env = {
  # Registry/private package restore.
  "DOCKERHUB_USERNAME" => local.fetch("dockerhub_username", "chthonicsystems"),
  "DOCKERHUB_TOKEN" => dig!(data, "dockerhub", "pat"),
  "GITHUB_USERNAME" => local.fetch("github_username", ENV.fetch("USER", "fakhrus")),
  "GITHUB_PACKAGES_PAT" => dig!(data, "local_deploy", "github_packages_pat"),

  # Public web build values.
  "REACT_APP_GOOGLE_CLIENT_ID" => dig!(data, "google_oauth", "android_client_id"),
  "REACT_APP_MICROSOFT_CLIENT_ID" => dig!(data, "local_deploy", "microsoft_client_id"),
  "REACT_APP_APPLE_CLIENT_ID" => local.fetch("apple_client_id", "com.chthonicsystems.torquetech.web"),
  "REACT_APP_FIREBASE_API_KEY" => dig!(data, "firebase", "android", "api_key"),
  "REACT_APP_FIREBASE_AUTH_DOMAIN" => "#{dig!(data, 'firebase', 'project_id')}.firebaseapp.com",
  "REACT_APP_FIREBASE_PROJECT_ID" => dig!(data, "firebase", "project_id"),
  "REACT_APP_FIREBASE_STORAGE_BUCKET" => dig!(data, "firebase", "storage_bucket"),
  "REACT_APP_FIREBASE_MESSAGING_SENDER_ID" => dig!(data, "firebase", "project_number"),
  "REACT_APP_FIREBASE_APP_ID" => dig!(data, "firebase", "android", "app_id"),
  "REACT_APP_FIREBASE_VAPID_KEY" => local.fetch("firebase_vapid_key", ""),

  # API runtime.
  "MYSQL_ROOT_PASSWORD" => dig!(data, "torquetech_deploy", "mysql_root_password"),
  "MYSQL_PASSWORD" => dig!(data, "torquetech_deploy", "mysql_password"),
  "JWT_SECRET" => dig!(data, "torquetech_deploy", "jwt_secret"),
  "FIREBASE_SERVICE_ACCOUNT_JSON" => JSON.generate(admin),
  "AWS_ACCESS_KEY_ID" => dig!(data, "aws_github_workflow", "access_key_id"),
  "AWS_SECRET_ACCESS_KEY" => dig!(data, "aws_github_workflow", "secret_access_key"),
  "AWS_SESSION_TOKEN" => local.fetch("aws_session_token", ""),
  "AWS_REGION" => local.fetch("aws_region", "ap-southeast-1"),
  "S3_BACKUP_BUCKET" => dig!(data, "local_deploy", "s3_backup_bucket"),
  "TWILIO_AUTH_TOKEN" => dig!(data, "local_deploy", "twilio_auth_token"),
  "GOOGLE_PLACES_API_KEY" => dig!(data, "google_places_api_key"),
  "GH_SUPPORT_TOKEN" => dig!(data, "gh_support_token"),
  "E2E_ADMIN_USERNAME" => dig!(data, "e2e_beta", "admin_username"),
  "E2E_ADMIN_PASSWORD" => dig!(data, "e2e_beta", "admin_password"),

  # Production provider values (base keys).
  "ACCOUNTING_LAUNCH" => "true",
  "STRIPE_SECRET_KEY" => dig!(data, "stripe_live", "secret_key"),
  "STRIPE_WEBHOOK_SECRET" => dig!(data, "stripe_live", "webhook_secret"),
  "STRIPE_CONNECT_WEBHOOK_SECRET" => dig_optional(data, "stripe_live", "connect_webhook_secret"),
  "PAYMENTS_PAY_LINK_SECRET" => dig!(data, "payments", "pay_link_secret"),
  "XERO_CLIENT_ID" => dig!(data, "xero", "prod", "client_id"),
  "XERO_CLIENT_SECRET" => dig!(data, "xero", "prod", "client_secret"),
  "XERO_WEBHOOK_KEY" => dig!(data, "xero", "prod", "webhook_signing_key"),
  "QB_CLIENT_ID" => dig!(data, "quickbooks", "prod", "client_id"),
  "QB_CLIENT_SECRET" => dig!(data, "quickbooks", "prod", "client_secret"),
  "QB_WEBHOOK_VERIFIER_TOKEN" => dig!(data, "quickbooks", "prod", "verifier_token"),

  # Beta provider overrides.
  "STRIPE_SECRET_KEY_BETA" => dig!(data, "stripe", "secret_key"),
  "STRIPE_WEBHOOK_SECRET_BETA" => dig!(data, "stripe", "webhook_secret"),
  "STRIPE_CONNECT_WEBHOOK_SECRET_BETA" => dig!(data, "stripe", "connect_webhook_secret"),
  "PAYMENTS_PAY_LINK_SECRET_BETA" => dig!(data, "payments", "pay_link_secret"),
  "XERO_CLIENT_ID_BETA" => dig!(data, "xero", "beta", "client_id"),
  "XERO_CLIENT_SECRET_BETA" => dig!(data, "xero", "beta", "client_secret"),
  "XERO_WEBHOOK_KEY_BETA" => dig!(data, "xero", "beta", "webhook_signing_key"),
  "QB_CLIENT_ID_BETA" => dig!(data, "quickbooks", "beta", "client_id"),
  "QB_CLIENT_SECRET_BETA" => dig!(data, "quickbooks", "beta", "client_secret"),
  "QB_WEBHOOK_VERIFIER_TOKEN_BETA" => dig!(data, "quickbooks", "beta", "verifier_token"),

  # Android/iOS release tooling.
  "KEYSTORE_PATH" => local.fetch("keystore_path", File.join(home, "chthonicsystems", "torquetech.keystore")),
  "KEYSTORE_PASSWORD" => dig!(data, "keystore", "password"),
  "KEY_ALIAS" => dig!(data, "keystore", "key_alias"),
  "KEY_PASSWORD" => dig!(data, "keystore", "key_password"),
  "AWS_S3_BUCKET_ANDROID" => dig!(data, "local_deploy", "android_s3_bucket"),
  "APP_STORE_CONNECT_API_KEY_ID" => dig!(data, "app_store_connect", "key_id"),
  "APP_STORE_CONNECT_API_ISSUER_ID" => dig!(data, "app_store_connect", "issuer_id"),
  "APP_STORE_CONNECT_API_KEY_PATH" => local.fetch("app_store_connect_key_path", File.join(home, "chthonicsystems", "AuthKey_#{dig!(data, 'app_store_connect', 'key_id')}.p8")),
  "MATCH_PASSWORD" => dig!(data, "match", "password"),
  "IOS_SIGNING_P12_PATH" => local.fetch("ios_signing_p12_path", File.join(home, "chthonicsystems", "distribution.p12")),
  "IOS_SIGNING_P12_PASSWORD" => dig!(data, "ios_distribution", "certificate_password")
}

File.chmod(0o600, output) if File.exist?(output)
File.open(output, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
  env.each do |key, value|
    abort "mapped value contains a newline: #{key}" if value.to_s.include?("\n")
    file.puts "#{key}=#{value}"
  end
end
File.chmod(0o600, output)
warn "mapped #{env.length} local deploy values from #{source}"
