require 'radiator'
require 'utils'
require 's_logger'

# NOTE: The total voting power is not a constant number like 1000
#   it will be closer to 1100 because:
#   when someone cast 100% voting when they have 80% vp left,
#   it will deduct 0.8 * 100 * 0.02 = 1.6% vp (not 2.0%)
#
#   We need to fix this correctly later

def current_voting_power(api = Radiator::Api.new)
  account = with_retry(3) do
    api.get_accounts(['steemhunt'])['result'][0]
  end
  vp_left = (account['voting_power'] / 100.0).round(2)

  last_vote_time = Time.parse(account['last_vote_time']) + Time.new.gmt_offset
  time_past = Time.now - last_vote_time

  # VP recovers (20/24)% per hour
  current_vp = (vp_left + (time_past / 3600.0) * (20.0/24.0)).round(2)

  current_vp > 100 ? 100.0 : current_vp
end

TEST_MODE = false # Should be false on production
TOTAL_VP_TO_USE = 1080.0
POWER_TOTAL_POST = if current_voting_power > 99.99
  TOTAL_VP_TO_USE * 0.8
else
  # NOTE:
  # If current VP is 70%, we need to only use 10% VP (= 540 VP)
  # This script should not run if POWER_TOTAL_POST < 0
  (TOTAL_VP_TO_USE - (TOTAL_VP_TO_USE * (100 - current_voting_power) / 20)) * 0.8
end
POWER_TOTAL_COMMENT = POWER_TOTAL_POST * 0.125 # 10% of total VP (Relative to posting total)
POWER_TOTAL_MODERATOR = TOTAL_VP_TO_USE * 0.10 # 10% of total VP (Fixed)
POWER_MAX = 100.0
MAX_POST_VOTING_COUNT = 1000
HUNT_DISTRIBUTION_VOTE = 40000.0
HUNT_DISTRIBUTION_RESTEEM = 20000.0

def get_minimum_power(size)
  min = POWER_TOTAL_POST / (size * 10.0)
  min = 100 if min > 100
  min = 0.01 if min < 0.01

  min
end

# def evenly_distributed_array(size)
#   return Array.new(size, POWER_MAX) if size <= POWER_TOTAL_POST /  POWER_MAX

#   average = POWER_TOTAL_POST / size
#   array = Array.new(size, average)
#   half = (size / 2).floor

#   variation = [POWER_MAX - array[0], array[size - 1] - get_minimum_power(size)].min / half

#   half.times do |i|
#     array[i] = array[i] + variation * (half - i)
#     array[size - i - 1] = array[size - i - 1] - variation * (half - i)
#   end

#   array.map { |n| n.round(2) }
# end

# Ref: https://github.com/Steemhunt/web/issues/102
def natural_distribution_test(size, temperature)
  orders = (1..size - 1).to_a
  exponents = orders.map { |o| Math.exp(o / temperature.to_f) }
  sum = exponents.sum
  softmaxes = exponents.map { |e| e / sum }

  minimum = get_minimum_power(size)
  allocated = Array.new(size, minimum)
  allocated[0] = POWER_MAX
  available = POWER_TOTAL_POST - POWER_MAX - minimum * (size - 1)

  (1..size - 1).each do |i|
    allocated[i] += (available * softmaxes[size -  i - 1])
  end

  allocated
end

def natural_distributed_array(size)
  return Array.new(size, POWER_MAX) if size <= POWER_TOTAL_POST /  POWER_MAX

  minimum = get_minimum_power(size)

  selected = nil
  (1..1000).each do |t|
    test_array = natural_distribution_test(size, t)
    if test_array.any? { |n| n > POWER_MAX || n < minimum ||  n.nan? }
      next
    else
      selected = test_array # first match, steepest possible
      break
    end
  end

  if selected.nil?
    raise "Distribution is not possible - POWER_TOTAL_POST: #{POWER_TOTAL_POST} / size: #{size}"
  else
    selected.map { |n| n.round(2) }
  end
end

def vote(author, permlink, power)
  tx = Radiator::Transaction.new(wif: ENV['STEEMHUNT_POSTING_KEY'])
  vote = {
    type: :vote,
    voter: 'steemhunt',
    author: author,
    permlink: permlink,
    weight: (power * 100).to_i
  }
  tx.operations << vote
  begin
    with_retry(3) do
      tx.process(!TEST_MODE)
    end
  rescue => e
    SLogger.log "FAILED VOTING: @#{author}/#{permlink} / POWER: #{power}"
  end
end

def comment(author, permlink, rank)
  msg = "### Congratulation! Your hunt was ranked in #{rank.ordinalize} place on #{formatted_date(Date.yesterday)} on Steemhunt.\n" +
    "We have upvoted your post for your contribution within our community.\n" +
    "Thanks again and look forward to seeing your next hunt!\n\n" +
    "Want to chat? Join us on:\n" +
    "* Discord: https://discord.gg/mWXpgks\n" +
    "* Telegram: https://t.me/joinchat/AzcqGxCV1FZ8lJHVgHOgGQ\n"

  tx = Radiator::Transaction.new(wif: ENV['STEEMHUNT_POSTING_KEY'])
  comment = {
    type: :comment,
    parent_author: author,
    parent_permlink: permlink,
    author: 'steemhunt',
    permlink: "re-#{permlink}-steemhunt",
    title: '',
    body: msg,
    json_metadata: {
      tags: ['steemhunt'],
      community: 'steemhunt',
      app: 'steemhunt/1.0.0',
      format: 'markdown'
    }.to_json
  }
  tx.operations << comment

  begin
    tx.process(!TEST_MODE)
  rescue => e
    SLogger.log "FAILED COMMENT: @#{author}/#{permlink} / RANK: #{rank}"
  end
end

def run_and_retry_on_exception(cmd, tries: 0, max_tries: 3, delay: 10)
  tries += 1
  run_or_raise(cmd)
rescue SomeException => exception
  report_exception(exception, cmd: cmd)
  unless tries >= max_tries
    sleep(delay) unless TEST_MODE
    retry
  end
end


def get_bid_bot_ids
  JSON.parse(File.read("#{Rails.root}/db/bid_bot_ids.json"))
end

def comment_already_voted?(comment, api)
  votes = with_retry(3) do
    api.get_content(comment['author'], comment['permlink'])['result']['active_votes']
  end

  votes.each do |vote|
    if vote['voter'] == 'steemhunt'
      return true
    end
  end

  return false
end

desc 'Voting bot'
task :voting_bot => :environment do |t, args|
  logger = SLogger.new

  if POWER_TOTAL_POST < 0
    logger.log "Less than 80% voting power left, STOP voting bot"
    next
  end

  api = Radiator::Api.new
  today = Time.zone.today.to_time
  yesterday = (today - 1.day).to_time

  logger.log "\n==\n========== VOTING STARTS with #{(POWER_TOTAL_POST * 1.25).round(2)}% TOTAL VP - #{formatted_date(yesterday)} ==========", true
  logger.log "Current voting power: #{current_voting_power(api)}%"
  posts = Post.where('created_at >= ? AND created_at < ?', yesterday, today).
               order('payout_value DESC').
               limit(MAX_POST_VOTING_COUNT).to_a

  logger.log "Total #{posts.size} posts found on #{formatted_date(yesterday)}\n==", true

  bid_bot_ids = get_bid_bot_ids
  review_comments = []
  moderators_comments =  []
  posts_to_skip = [] # posts that should skip votings, but need to be counted for VP
  posts_to_remove = [] # posts  that should be removed from the ranking entirely (not counted for VP)

  # For voting / resteem contributions
  rshares_by_users = {}
  has_resteemed = {}
  posts.each_with_index do |post, i|
    logger.log "@#{post.author}/#{post.permlink}"

    unless post.is_verified
      posts_to_remove << post.id
      post.update! created_at: Time.now # pass it over to the next date
      logger.log "--> REMOVE: Not yet verified"
      next
    end

    # Get data from blockchain
    result = with_retry(3) do
      api.get_content(post.author, post.permlink)['result']
    end
    votes = result['active_votes']

    if post.is_active
      if result['title'].blank?
        posts_to_remove << post.id
        logger.log "--> REMOVE: No blockchain data on Steem -------------->>> ACTION REQUIRED"
        next
      end

      logger.log "--> VOTE COUNT: #{votes.size}"
      votes.each do |vote|
        if vote['voter'] == 'steemhunt'
          posts_to_skip << post.id
          logger.log "--> SKIP: Already voted"
        elsif !bid_bot_ids.include?(vote['voter'])
          if rshares_by_users[vote['voter']]
            rshares_by_users[vote['voter']] += vote['rshares'].to_i
          else
            rshares_by_users[vote['voter']] = vote['rshares'].to_i
          end
        end
      end

      resteemed_by = with_retry(3) do
        api.get_reblogged_by(post.author, post.permlink)['result']
      end

      logger.log "--> RESTEEM COUNT: #{resteemed_by.size}"
      resteemed_by.each do |username|
        has_resteemed[username] = true unless has_resteemed[username]
      end
    else
      posts_to_remove << post.id
      logger.log "--> HIDDEN: still checks comments for moderators and review comments"
    end

    comments = with_retry(3) do
      api.get_content_replies(post.author, post.permlink)['result']
    end
    # logger.log "----> #{comments.size} comments returned"

    review_commnet_added = {}
    comments.each do |comment|
      json_metadata = JSON.parse(comment['json_metadata']) rescue {}

      is_review = comment['body'] =~ /pros\s*:/i && comment['body'] =~ /cons\s*:/i
      is_moderator = !json_metadata['verified_by'].blank?

      if is_review || is_moderator
        should_skip = comment_already_voted?(comment, api)

        # 1. Moderator comments
        if is_moderator
          if  User::MODERATOR_ACCOUNTS.include?(comment['author'])
            moderators_comments.push({ author: comment['author'], permlink: comment['permlink'], should_skip: should_skip })
            logger.log "--> #{should_skip ? 'SKIP ALREADY_VOTED' : 'ADDED'} Moderator comment: @#{comment['author']}"
          else
            logger.log "--> WTF!!!!! Moderator comment: @#{comment['author']}/#{comment['permlink']}"
          end
        # 2. Review comments
        elsif is_review
          if review_commnet_added[comment['author']]
            logger.log "--> REMOVE DUPLICATED_REVIEW_COMMENT by user: @#{comment['author']}"
          # TODO: Uncomment after announcement
          # elsif comment['body'].size < 80
          #   logger.log "--> REMOVE TOO_SHORT_REVIEW_COMMENT by user: @#{comment['author']}"
          # elsif !votes.any? { |v| v['voter'] == comment['author'] && v['percent'] > 5000 }
          #   logger.log "--> REMOVE NOT_VOTED_REVIEW_COMMENT by user: @#{comment['author']}"
          # elsif comment['author'] == post.author
          #   logger.log "--> REMOVE SELF_REVIEW_COMMENT by user: @#{comment['author']}"
          else
            review_comments.push({ author: comment['author'], permlink: comment['permlink'], should_skip: should_skip })
            review_commnet_added[comment['author']] = true
            logger.log "--> #{should_skip ? 'SKIP ALREADY_VOTED' : 'ADDED'} Review comment: @#{comment['author']}"
          end
        end
      end
    end # comments.each
  end # posts.each

  posts = posts.to_a.reject { |post| posts_to_remove.include?(post.id) }
  vp_distribution = natural_distributed_array(posts.size)

  # 1. HUNT voting distribution
  total_rshares = rshares_by_users.values.sum.to_f
  rshares_by_users = rshares_by_users.sort_by {|k,v| v}.reverse
  logger.log "\n==\n========== #{HUNT_DISTRIBUTION_VOTE} HUNT DISTRIBUTION ON #{rshares_by_users.size} VOTERS ==========\n==", true

  rshares_by_users.each do |pair|
    username = pair[0]
    proportion = pair[1] / total_rshares
    hunt_amount = HUNT_DISTRIBUTION_VOTE * proportion

    # TODO: uncomment it for actual distribution
    logger.log "TEST - @#{username} received #{hunt_amount.round(2)} HUNT - #{(100 * proportion).round(4)}%"
    # HuntTransaction.reward_votings!(username, hunt_amount, yesterday) unless TEST_MODE
    # logger.log "@#{username} received #{hunt_amount.round(2)} HUNT - #{(100 * proportion).round(4)}%"
  end

  # 2. HUNT resteem distribution
  resteemed_users = has_resteemed.keys
  hunt_per_resteem = HUNT_DISTRIBUTION_RESTEEM / resteemed_users.size
  logger.log "\n==\n========== #{HUNT_DISTRIBUTION_RESTEEM} HUNT DISTRIBUTION ON #{resteemed_users.size} RESTEEMERS ==========\n==", true

  resteemed_users.each do |username|
    # TODO: uncomment it for actual distribution
    # HuntTransaction.reward_resteems!(username, hunt_per_resteem, yesterday) unless TEST_MODE
  end
  logger.log "TEST - Distributed #{hunt_per_resteem} HUNT to #{resteemed_users.size} users"
  # TODO: uncomment it for actual distribution
  # logger.log "Distributed #{hunt_per_resteem} HUNT to #{resteemed_users.size} users"

  logger.log "\n==\n========== VOTING ON #{posts.size} POSTS with #{POWER_TOTAL_POST.round(2)}% VP ==========\n==", true

  posts.each_with_index do |post, i|
    ranking = i + 1
    voting_power = vp_distribution[ranking - 1]

    logger.log "Voting on ##{ranking} (#{voting_power.round(2)}%): @#{post.author}/#{post.permlink}"
    if posts_to_skip.include?(post.id)
      logger.log "--> SKIPPED_POST"
    else
      sleep(20) unless TEST_MODE
      res = vote(post.author, post.permlink, voting_power)
      logger.log "--> VOTED_POST: #{res.try(:result).try(:id) || res.try(:error)}"
      res = comment(post.author, post.permlink, ranking)
      logger.log "--> COMMENTED: #{res.try(:result).try(:id) || res.try(:error)}", true
    end
  end

  logger.log "\n==\n========== VOTING ON #{review_comments.size} REVIEW COMMENTS with #{POWER_TOTAL_COMMENT.round(2)}% VP ==========\n==", true

  voting_power = (POWER_TOTAL_COMMENT / review_comments.size).floor(2)
  voting_power = 100.0 if voting_power > 100
  review_comments.each do |comment|
    logger.log "Voting on review comment (#{voting_power}%): @#{comment[:author]}/#{comment[:permlink]}", true
    if comment[:should_skip]
      logger.log "--> SKIPPED_REVIEW", true
    else
      sleep(3) unless TEST_MODE
      res = vote(comment[:author], comment[:permlink], voting_power)
      logger.log "--> VOTED_REVIEW: #{res.try(:result).try(:id) || res.try(:error)}", true
    end
  end

  logger.log "\n==\n========== VOTING ON #{moderators_comments.size} MODERATOR COMMENTS with #{POWER_TOTAL_MODERATOR.round(2)}% VP ==========\n==", true

  voting_power = (POWER_TOTAL_MODERATOR / moderators_comments.size).floor(2)
  voting_power = 100.0 if voting_power > 100
  moderators_comments.each do |comment|
    logger.log "Voting on moderator comment (#{voting_power}%): @#{comment[:author]}/#{comment[:permlink]}", true
    if comment[:should_skip]
      logger.log "--> SKIPPED_MODERATOR", true
    else
      sleep(3) unless TEST_MODE
      res = vote(comment[:author], comment[:permlink], voting_power)
      logger.log "--> VOTED_MODERATOR: #{res.try(:result).try(:id) || res.try(:error)}", true
    end
  end

  logger.log "Votings Finished, #{current_voting_power(api)}% VP left", true
end