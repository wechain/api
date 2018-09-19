class HuntTransactionsController < ApplicationController
  before_action :ensure_login!, except: [:status]

  # GET /hunt_transactions.json
  def index
    @transactions = HuntTransaction.
      where('sender = ? OR receiver = ?', @current_user.username, @current_user.username).
      order(created_at: :desc).
      limit(500)

    @withdrawals = ErcTransaction.
      where(user_id: @current_user.id).
      order(created_at: :desc).
      limit(500)

    render json: {
      balance: @current_user.hunt_balance,
      eth_address: @current_user.eth_address,
      transactions: @transactions,
      withdrawals: @withdrawals
    }
  end

  def status
    sum = Rails.cache.fetch('statufds', expires_in: 1.second) do
      {
        record_time: Time.now.strftime("%B #{Time.now.day.ordinalize}, %Y"),
        airdrops: HuntTransaction.group(:bounty_type).sum(:amount)
      }
    end

    airdrops = {
      sp_holders: {
        label: "SP Holders (Completed)", data: sum[:airdrops]['sp_claim'].to_f, disabled: true
      },
      sponsors: {
        label: "Sponsors", data: sum[:airdrops]['sponsor'].to_f, disabled: false
      },
      promotion_contributors: {
        label: "Promotion Contributors", data: sum[:airdrops]['contribution'].to_f, disabled: false
      },
      hunt_post_voters: {
        label: "Hunt Post Voters", data: sum[:airdrops]['voting'].to_f, disabled: false
      },
      role_contributors: {
        label: "Role Contributors", data: (sum[:airdrops]['report'] + sum[:airdrops]['moderator'] + sum[:airdrops]['guardian']).to_f, disabled: false
      },
      social_shares: {
        label: "Social Shares", data: sum[:airdrops]['social_share'].to_f, disabled: false
      },
      resteemers: {
        label: "Resteemers", data: sum[:airdrops]['resteem'].to_f, disabled: true
      }
    }

    render json: {
      record_time: sum[:record_time],
      total: sum[:airdrops].values.sum.to_f,
      days_passed: (DateTime.now - "2018-05-22".to_datetime).to_i,
      airdrops: Hash[airdrops.sort_by {|k, v| v[:data] }.reverse]
    }
  end

  private
    def user_params
      params.require(:user).permit(:username, :token)
    end
end