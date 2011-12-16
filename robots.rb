#
# SacRuby December 2011 Mini-Hack-a-thon
#
# This little hacked up program provides a "server" for the
# game "robots!". Challenge is to build a client for the game
# (using any technology you wish) that allows you to play
# interactively using the RESTful interface.
#
# Bonus points if you can write a "bot" to play for you!
# 
# Set up and run with:
#   (install sqlite3, e.g. brew install sqlite3)
#   bundle install
#   bundle exec ruby robots.rb 
#
#
# TODO: Add handling of end game better
#

require 'rubygems'
require 'sinatra'
require 'sqlite3'
require 'data_mapper'
require 'haml'
require 'json'

mime_type :json, "application/json"

DataMapper::setup(:default, "sqlite3://#{Sinatra::Application.root}/db/robots.db")

configure(:production, :development) do
  enable :logging
end

class Game
  include DataMapper::Resource
  property :id,   Serial
  property :name, String
  property :board_size, Integer
  property :turn, Integer
  property :active, Boolean
  has n, :players
  property :created_at, DateTime
  property :updated_at, DateTime
  property :processing, Boolean, :default => false
  belongs_to :winner, 'Player', :required => false
  
  FACINGS = %w(N E S W)
  FACINGS_VISUAL = {'N' => '^', 'S' => 'v', 'W' => '<', 'E' => '>'}
  ORDERS_PER_TURN = 3
  STARTING_HITPOINTS = 5
  MIN_BOARD_SIZE = 10
  MAX_BOARD_SIZE = 100
  SCORE_TO_WIN = 10
  PLAYERS_PER_GAME=9
    
  # Render the board for visual display
  def draw(eol = "\n")
    player_positions = {}
    players.each do |p| 
      unless p.state == 'quit'
        player_positions[p.x_pos] ||= {}
        player_positions[p.x_pos][p.y_pos] = p
      end
    end
    buf = ""
    start = 0
    size = board_size - 1
    for x in 0..size do
      for y in 0..size do
        start += 1
        if p = (player_positions[x] && player_positions[x][y])
          klass = ' occupied'
          spot = "#{p.id}#{FACINGS_VISUAL[p.facing]}"
        else
          klass = nil
          spot = '.'
        end
        buf += "<span class='space#{klass}'>#{spot}</span>"
      end
      buf+=eol
    end
    buf
  end
  
  def board_as_array
    player_positions = {}
    players.each do |p| 
      unless p.state == 'quit'
        player_positions[p.x_pos] ||= {}
        player_positions[p.x_pos][p.y_pos] = p
      end
    end
    buf = []
    size = board_size - 1
    for x in 0..size do
      row = []
      for y in 0..size do
        if p = (player_positions[x] && player_positions[x][y])
          puts "Player: #{p.id} #{p.hp}"
          facing = p.hp > 0 ? FACINGS_VISUAL[p.facing] : '*'
          spot = "#{p.id}#{facing}"
        else
          spot = '.'
        end
        row << spot
      end
      buf << row
    end
    buf
  end
  
  # find a location on virtual board without another player
  def initialize_position
    done = false
    pos = {:facing => Game::FACINGS[rand(4)]}
    while not done do
      start_at = rand(board_size * board_size)
      start_at = [start_at / board_size, start_at % board_size]
      done = players(:x_pos => start_at[0], :y_pos => start_at[1]).empty?
    end
    pos[:x] = start_at[0]
    pos[:y] = start_at[1]
    pos
  end
  
  def add_player(name)
    start_at = initialize_position
    player = Player.new(:name => name, :x_pos => start_at[:x], :y_pos => start_at[:y], :facing => start_at[:facing], :hp => Game::STARTING_HITPOINTS, :score => 0, :orders => "." * Game::ORDERS_PER_TURN, :state => 'ready', :active => true)
    player.game = self
    player = player.save ? player : nil
    player
  end
  
  def game_hash
    {:name => name, :id => id, :board_size => board_size, :turn => turn, :board => board_as_array, :active => active}
  end
  
  # Resolve orders
  def execute_order(player, phase)
    order = player.orders[phase]
    puts "Running #{order}"
    case order
    when 'F'
      move_forward(player)
    when 'R', 'L'
      change_facing(player, order)
    when 'X'
      fire_weapon(player)
    else
      # no-op
    end
  end

  def move_forward(player)
    # check for  wall or players in the way
    case player.facing
    when 'N'
      unless player.x_pos <= 0 or Player.get(:x_pos => player.x_pos - 1, :y_pos => player.y_pos)
        player.x_pos -= 1
      end
    when 'E'
      unless player.y_pos >= board_size - 1 or Player.get(:x_pos => player.x_pos, :y_pos => player.y_pos + 1)
        player.y_pos += 1
      end
    when 'S'
      unless player.x_pos >= board_size - 1 or Player.get(:x_pos => player.x_pos + 1, :y_pos => player.y_pos)
        player.x_pos += 1
      end
    when 'W'
      unless player.y_pos <= 0 or Player.get(:x_pos => player.x_pos, :y_pos => player.y_pos - 1)
        player.y_pos -= 1
      end
    end
  end
  
  def change_facing(player, direction)
    increment = direction == "R" ? 1 : -1
    player.facing = FACINGS[(FACINGS.index(player.facing) + increment) % FACINGS.length]
  end
  
  def fire_weapon(player)
    # check for players in the way and hit them!
    target = case player.facing
    when 'N'
      Player.all(:x_pos.lt => player.x_pos, :y_pos => player.y_pos, :order => [:x_pos.desc]).first
    when 'E'
      Player.all(:x_pos => player.x_pos, :y_pos.gt => player.y_pos, :order => [:x_pos.asc]).first
    when 'S'
      Player.all(:x_pos.gt => player.x_pos, :y_pos => player.y_pos, :order => [:x_pos.asc]).first
    when 'W'
      Player.all(:x_pos => player.x_pos, :y_pos.lt => player.y_pos, :order => [:x_pos.asc]).first
    end
    if target and target.hp > 0
      # target loses a hitpoint, and if reduced to zero is DEAD
      target.hp -= 1
      target.save
      player.score += 1
      player.save
    end
  end
  
  # See if we should run a game turn
  def tick
    if players.all?{|p| %w(waiting quit lost won ready).include?(p.state)} and not processing
      self.processing = true
      save
      
      # TODO: randomize an order and walk through orders
      
      # run orders
      0.upto(ORDERS_PER_TURN) do |phase|
        players.each do |player|
          puts "Running turn for #{player.id} phase #{phase}"
          execute_order(player, phase) if player.active
        end
      end
      
      # update turn
      self.turn += 1
      # update players state
      lost_count = 0
      players.each do |p|
        if p.state == 'waiting'
          p.state = if p.hp <= 0
            lost_count += 1
            'lost'
          elsif p.score >= SCORE_TO_WIN
            self.winner = p
            'won'
          else
            'ready'
          end
          p.save
        end
      end
      
      if winner
        players.each do |p| 
          if p.score < SCORE_TO_WIN and !%(won quit).include?(p.state)
            p.state = 'lost'; p.save
          end
        end
        self.active = false
      end
      
      self.processing = false
      save
    end
  end
end

Game.raise_on_save_failure = true  

class Player
  include DataMapper::Resource
  property :id, Serial
  property :name, String
  property :x_pos, Integer
  property :y_pos, Integer
  property :facing, String
  belongs_to :game, :required => false
  property :joined_at, DateTime
  property :active, Boolean
  property :hp, Integer
  property :score, Integer
  property :orders, String
  property :state, String
  
  # 
  STATES = %w(ready waiting stopped won lost quit)
  
  def player_hash
    {:id => id, :name => name, :x => x_pos, :y => y_pos, :facing => facing, :hp => hp, :score => score, :state => state, :orders => orders}
  end
  
  def enter_orders(new_orders=('.' * Game::ORDERS_PER_TURN))
    self.orders = new_orders[0..Game::ORDERS_PER_TURN].upcase
    self.state = 'waiting'
    save
  end
  
  def leave_game
    self.state = 'quit'
    self.orders = '.' * Game::ORDERS_PER_TURN
    self.active = false
    self.x_pos = nil
    self.y_pos = nil
    self.facing = nil
    save
  end
end

DataMapper.finalize
DataMapper.auto_upgrade!

before do
  headers "Content-Type" => "text/html; charset=utf-8"
end

# UI
get '/' do
  @title = "Welcome to Robots"
  @games = Game.all
  haml :index
end

# API: /games
# Purpose: Get List of all games. Use this to pick a game to join
#
# returns a JSON array of
# Game ID: id
# Is Game Active?: active
# Board Size (always square): size
# Number of Players: players
# Current turn (starts at 1): turn
get '/games', :provides => :json do
  @games = Game.all
  @games.collect{|g| {:id => g.id, :active => g.active, :size => g.board_size, :name => g.name, :players => g.players.length, :turn => g.turn}}.to_json
end

# UI:
# Params: name and size (to create a game)
post '/game' do
  size = params[:size].to_i
  size = [[size, Game::MAX_BOARD_SIZE].min, Game::MIN_BOARD_SIZE].max
  @game = Game.new(:turn => 1, :name => params[:name], :board_size => size, :active => true)
  if @game.save
    redirect "/game/#{@game.id}"
  else
    redirect('/')
  end
end

# UI
# Show Specific Game Detail
get '/game/:id', :provides => 'html' do
  if @game = Game.get(params[:id])
    haml :show
  else
    pass
  end
end
  
# API: /game/:id (game id)
# Return JSON version of details about specific game
# {:name => name, :id => id, :board_size => board_size, :turn => turn, :board => board, :active => active}
#
get '/game/:id', :provides => 'json' do
  if @game = Game.get(params[:id])
    @game.game_hash.to_json
  else
    pass
  end
end
  
# API: /join/:id (game id)
# Join a game and create a player
# POST params:
#   :name = Player's name
# Returns JSON version of:
# {:name => name, :id => id, :board_size => board_size, :turn => turn, :board => board, :active => active, :player => {:id => id, :name => name, :x => x_pos, :y => y_pos, :facing => facing, :hp => hp, :score => score, :state => state, :orders => orders} }
post '/join/:id', :provides => 'json' do
  if @game = Game.get(params[:id]) and @game.active and @player = @game.add_player(params[:name])
    @game.game_hash.merge({:player => @player.player_hash}).to_json
  else
    pass
  end
end

# UI
# Join a game
post '/join', :provides => 'html' do
  if @game = Game.get(params[:id]) and @game.active and @player = @game.add_player(params[:name])
    haml :show_player
  else
    pass
  end
end


# UI
# Get Player details
get '/player/:id', :provides => 'html' do  
  if @player = Player.get(params[:id])
    @game = @player.game
    haml :show_player
  else
    redirect('/')
  end
end


# API: /player/:id (player id)
# Get current player status/details
# Returns JSON version of
# {:id => id, :name => name, :x => x_pos, :y => y_pos, :facing => facing, :hp => hp, :score => score, :state => state, :orders => orders}
get '/player/:id', :provides => 'json' do  
  if @player = Player.get(params[:id])
    @player.player_hash.to_json
  else
    pass
  end
end


# pass orders, which is a string of one of
# F = move forward one space
# R = turn 90 clockwise
# L = turn 90 counterclockwise
# . = idle (noop)
# X = fire shot
# UI
# Submit a turn
post '/turn/:id', :provides => 'html' do
  if @player = Player.get(params[:id])
    if @player.state == 'ready'
      @player.enter_orders(params[:orders])
      @player.game.tick
      @player.reload
      @message = 'accepted'
    else
      @message = 'still waiting'
    end
    @game = @player.game
    haml :show_player
  else
    pass
  end
end

# API /turn/:id (player id)
# Submit your turn
# POST params
#   orders = string of 3 characters from order command codes
# Returns JSON version of 
# {:id => id, :name => name, :x => x_pos, :y => y_pos, :facing => facing, :hp => hp, :score => score, :state => state, :orders => orders}
post '/turn/:id', :provides => 'json' do
  if @player = Player.get(params[:id])
    if @player.state == 'ready'
      @player.enter_orders(params[:orders])
      @player.game.tick
      @player.reload      
      @player.player_hash.to_json
    else
      halt
    end
  else
    pass
  end
end
# UI:
# Quit a game
post '/leave/:id', :provides => 'html' do
  if @player = Player.get(params[:id])
    @player.leave_game
    @game = @player.game
    haml :show_player
  else
    pass
  end
end

# API: /leave/:id (player id)
# After you quit a game, your piece is removed from the board and you can't submit further actions
# Returns JSON version of 
# {:id => id, :name => name, :x => x_pos, :y => y_pos, :facing => facing, :hp => hp, :score => score, :state => state, :orders => orders}
post '/leave/:id', :provides => 'json' do
  if @player = Player.get(params[:id])
    @player.leave_game
    @player.player_hash.to_json
  else
    pass
  end
end

# UI:
# Quit a game
post '/tick/:id', :provides => 'html' do
  if @game = Game.get(params[:id])
    @game.processing = false
    @game.tick
    haml :show
  else
    pass
  end
end
