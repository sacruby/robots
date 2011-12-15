require 'rest-client'
require 'json'

class Player
  ROOT = "http://10.40.232.94:4567"

  def req(ignore)
    yield
  rescue JSON::ParserError
    raise unless ignore
  end

  def get(path, params={})
    req(params.delete(:ignore){JSON.parse(RestClient.get("#{ROOT}/#{path}", :params => params, :accept => :json))}
  end

  def post(path, params={})
    req(params.delete(:ignore)){RestClient.post("#{ROOT}/#{path}", params, :content_type => :json, :accept => :json)}
  end

  def self.new_game(name)
    post("game", :name=>name)
  end

  def self.list
    get('games')
  end

  def self.join(game_id, name)
    info = post("join/#{game_id}", :name=>name)
    new(game_id, info['player']['id'])
  end

  attr_reader :game_id, :player_id

  def initialize(game_id, player_id)
    @game_id = game_id
    @player_id = player_id
  end

  def info(*ids)
    players.map{|id| p get("player/#{id}", :ignore=>true)}
    nil
  end

  def game_info
    get("game/#{game_id}")
  end

  def turn(s, id=player_id)
    post("turn/#{id}", :orders=>s)
  end

  def idle(*ids)
    ids.each{|id| turn('...', id)}
  end

  def players
    game_info['board'].map{|r| r.grep /\d/}.flatten.map{|c| c.to_i}
  end

  def idle_thread(*ids)
    ids = players - [player_id] if ids.empty?
    Thread.new{loop{ids.each{|id| idle(id) rescue nil}; sleep 1}}
  end

  def show
    puts game_info['board'].map{|r| r.map{|c| sprintf('%03s', c)}.join(' ')}.join("\n")
  end
end

Me = Player.new(5, 19)
