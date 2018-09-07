class ReferralController < ApplicationController
  BOT_UA = /curl|googlebot|bingbot|yandex|baiduspider|twitterbot|facebookexternalhit|rogerbot|linkedinbot|embedly|quora link preview|showyoubot|outbrain|pinterest|slackbot|vkShare|W3C_Validator|developers\.google\.com|Google-Structured-Data-Testing-Tool|redditbot|Discordbot|TelegramBot/i

  def create
    unless user = User.find_by(username: params[:ref])
      render head: :not_found and return
    end

    if request.user_agent =~ BOT_UA
      render head: :not_acceptable and return
    end

    begin
      Referral.create(
        user_id: user.id,
        remote_ip: request.remote_ip,
        path: params[:path],
        referrer: params[:referrer],
        user_agent: request.user_agent
      )

      render head: :ok
    rescue ActiveRecord::RecordNotUnique
      render head: :conflict
    end
  end
end
