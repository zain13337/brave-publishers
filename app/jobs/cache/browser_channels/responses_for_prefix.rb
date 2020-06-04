class Cache::BrowserChannels::ResponsesForPrefix
  include Sidekiq::Worker
  sidekiq_options queue: :low, retry: false

  PATH = "publishers/prefixes/".freeze
  PADDING_WORD = "P".freeze

  attr_accessor :site_banner_lookups, :channel_responses, :temp_file

  def perform(prefix)
    generate_brotli_encoded_channel_response(prefix: prefix)
    pad_file!
    save_to_s3!(prefix: prefix) unless Rails.env.test?
    cleanup!
  end

  def generate_brotli_encoded_channel_response(prefix:)
    @site_banner_lookups = SiteBannerLookup.where("sha2_base16 LIKE ?", prefix + "%")
    @channel_responses = PublishersPb::ChannelResponseList.new
    @site_banner_lookups.each do |site_banner_lookup|
      channel_response = PublishersPb::ChannelResponse.new
      channel_response.channel_identifier = site_banner_lookup.channel_identifier
      channel_response.wallet_connected_state = site_banner_lookup.wallet_status
      channel_response.wallet_address = site_banner_lookup.wallet_address if site_banner_lookup.wallet_address.present?
      channel_response.site_banner_details = get_site_banner_details(site_banner_lookup)
      channel_responses.channel_responses.push(channel_response)
    end

    json = PublishersPb::ChannelResponseList.encode(channel_responses)
    info = Brotli.deflate(json)
    @temp_file = Tempfile.new.binmode
    # Write a 4-byte header saying the payload length
    @temp_file.write([info.length].pack("N"))
    @temp_file.write(info)
    @temp_file.close
    @temp_file
  end

  private

  def cleanup!
    begin
      File.open(@temp_file.path, 'r') do |f|
        File.delete(f)
      end
    rescue Errno::ENOENT
    end
  end

  # We want to hide which file is being downloaded by making all requests be the same size
  def pad_file!
    path = @temp_file.path
    # Round up to nearest KB
    file_size = File.size(path)
    # Converts size from like 326 to 1000
    new_size = (((file_size + 1000) / 1000)) * 1000
    delta = new_size - file_size
    # I'm assuming padding will be fast in a for loop, this can be optimized if this is slow
    # if moving around the file on disk is a frequent operation
    File.open(path, 'ab') do |f|
      f.write(PADDING_WORD * delta)
      f.close
    end
  end

  def save_to_s3!(prefix:)
    path = @temp_file.path
    Aws.config[:credentials] = Aws::Credentials.new(Rails.application.secrets[:s3_rewards2_access_key_id], Rails.application.secrets[:s3_rewards2_secret_access_key])
    s3 = Aws::S3::Resource.new(region: Rails.application.secrets[:s3_rewards2_bucket_region])
    obj = s3.bucket(Rails.application.secrets[:s3_rewards2_bucket_name]).object(PATH + prefix)
    obj.upload_file(path)
  end

  def get_site_banner_details(site_banner_lookup)
    details = PublishersPb::SiteBannerDetails.new
    site_banner_lookup.derived_site_banner_info.keys.each do |key|
      # Convert to snake_case
      value = site_banner_lookup.derived_site_banner_info[key]
      next if value.nil? || value.is_a?(Hash) || value.is_a?(Array)
      details[key.underscore] = value
    end

    if site_banner_lookup.derived_site_banner_info["donationAmounts"].present? && site_banner_lookup.derived_site_banner_info["donationAmounts"] != SiteBanner::DEFAULT_AMOUNTS
      # Confusing. This is the suggested implementation (no, normal assignment doesn't work)
      # https://github.com/protocolbuffers/protobuf/issues/320
      details.donation_amounts += site_banner_lookup.derived_site_banner_info["donationAmounts"]
    end

    if site_banner_lookup.derived_site_banner_info["socialLinks"].present?
      social_links_pb = nil
      site_banner_lookup.derived_site_banner_info["socialLinks"].each do |domain, handle|
        if handle.present?
          social_links_pb = PublishersPb::SocialLinks.new if social_links_pb.nil?
          social_links_pb[domain] = handle
        end
      end
      details.social_links = social_links_pb if social_links_pb.present?
    end
    details
  end
end
