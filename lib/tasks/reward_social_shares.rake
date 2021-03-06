require 'radiator'
require 's_logger'
require 'utils'

desc 'Reward Social Shares'
task :reward_social_shares => :environment do |t, args|
  HUNT_DISTRIBUTION_SOCIAL = 90000.0
  MAX_BOUNTY_PER_SHARE = 200
  MAX_SHARE_PER_DAY = 50

  logger = SLogger.new('reward-log')
  logger.log "\n==========\n#{HUNT_DISTRIBUTION_SOCIAL} HUNT DISTRIBUTION ON SOCIAL SHARES", true

  today = Time.zone.today
  referrals = Referral.where(bounty_given: -1)
  user_counts = referrals.group(:user_id).count.sort_by { |c| c[1] }.reverse
  total_count = user_counts.inject(0) { |sum, c| sum + c[1] }
  effective_count = user_counts.inject(0) { |sum, c| sum + (c[1] > MAX_SHARE_PER_DAY ? MAX_SHARE_PER_DAY : c[1]) }
  logger.log "Total #{total_count} traffic lead today (#{effective_count} effective for bounty distribution)"

  # Just info
  referrer_counts = referrals.group(:referrer).count.sort_by { |c| c[1] }.reverse
  referrer_counts.each do |r|
    logger.log "  - #{r[1]} visits from #{r[0]}"
  end
  logger.log "==========", true

  if total_count == 0
    logger.log "All bounties have been processed"
    exit(0)
  end

  # 1/n of total bounty / Max 100 HUNTs
  bounty_per_share = HUNT_DISTRIBUTION_SOCIAL / effective_count
  bounty_per_share = MAX_BOUNTY_PER_SHARE if bounty_per_share > MAX_BOUNTY_PER_SHARE

  total_given = 0
  user_counts.each do |c|
    user = User.find(c[0])
    share_count = c[1] > MAX_SHARE_PER_DAY ? MAX_SHARE_PER_DAY : c[1]
    bounty = share_count * bounty_per_share

    begin
      HuntTransaction.reward_social_shares! user.username, bounty, today
    rescue => e
      logger.log "ERROR - #{e}"
      next
    end
    total_given += bounty

    logger.log "@#{user.username} - share count: #{c[1]} - #{formatted_number(bounty)} HUNTs"
  end

  referrals.update_all bounty_given: bounty_per_share

  logger.log "=========="
  logger.log "FINISHED SOCIAL SHARE DISTRIBUTION - #{formatted_number(total_given)} HUNTs to #{total_count} => #{effective_count} traffic lead by  #{user_counts.count} users (#{today})"
  logger.log "==========", true
end

