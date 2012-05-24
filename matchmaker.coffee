###
Matchmaker
  This is it, the magic matchmaker. See the docs for further information

(c) 2012, Schiffchen Team <schiffchen@dsx.cc>
###

#-----------------------------------------------------------------------------#

xmpp = require('node-xmpp')
mysql = require('mysql')

# I feel like I have to expand the String object because
# I like to have a startsWith()
if typeof String.prototype.startsWith != 'function'
  String.prototype.startsWith = (str) ->
    this.indexOf(str) == 0
    
#-----------------------------------------------------------------------------#
    
dbc = mysql.createClient({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
})

dbc.query('USE ' + process.env.DB_DATABASE)

#-----------------------------------------------------------------------------#

class BasicBot
  constructor: (@xmppClient) ->
  
  say: (to, message) ->
    @xmppClient.send new xmpp.Element('message', {'type': 'chat', 'to': to})
      .c('body').t(message)
      
#-----------------------------------------------------------------------------#

class MatchMaker extends BasicBot
  constructor: (@xmppClient) ->
    @queue = new Queue(@)
    super(@xmppClient)
    
  showReadyStatus: ->
    @xmppClient.send new xmpp.Element('presence', {})
      .c('show').t('chat').up()
      .c('status').t('The matchmaker is ready!').up()
      .c('priority').t('0')
    
  showBusyStatus: ->
    @xmppClient.send new xmpp.Element('presence', {})
      .c('show').t('dnd').up()
      .c('status').t('Too busy right now, try again later.').up()
      .c('priority').t('0')

  handleStanza: (stanza) ->
    if stanza.attrs.type != 'error'
      switch stanza.name
        when 'message'
          if stanza.type == 'chat'
            @processCommand(stanza)
            @processAction(stanza)
          else if stanza.type == 'normal'
            @processAction(stanza)

  processCommand: (stanza) ->
    body = stanza.getChild('body')
    if body
      message = body.getText()
      if message.startsWith('help')
        @help(stanza.from)
      else if message.startsWith('count players')
        dbc.query('SELECT count(*) FROM players;', (error, response) =>
          @say(stanza.from, "Okay! I found #{response[0]['count(*)']} players.")
        )
        
  processAction: (stanza) ->
    battleship = stanza.getChild('battleship')
    if battleship
      if queueing = battleship.getChild('queueing')
        if queueing.attrs.action == 'request'
          @queue.enqueueUser(stanza)
  
  help: (to) ->
    @say(to, """You wanna help? Here you are:
      help - Shows this message
      count players - Counts all players in the database""")

#-----------------------------------------------------------------------------#

class Queue
  constructor: (mm) ->
    @mm = mm
        
  enqueueUser: (stanza) ->
    jidParts = stanza.from.split('/')
    id = 0

    dbc.query("SELECT id FROM players WHERE jid='#{jidParts[0]}' LIMIT 1", (error, response) =>
      if response[0]
        id = response[0]['id']
        @addToQueue(id, jidParts[1])
      else
        dbc.query("INSERT INTO players (jid) VALUES ('#{jidParts[0]}');
          SELECT id FROM players WHERE jid='#{jidParts[0]}' LIMIT 1", (error, response) => 
          @addToQueue(response['insertId'], jidParts[1])
        )
    )
    
  addToQueue: (uid, resource) ->
    timestamp = Math.round((new Date()).getTime() / 1000)
    # ToDo: Handle duplicate queue entries
    dbc.query("INSERT INTO queue (queued_at, user_id, resource) VALUES (#{timestamp}, #{uid}, '#{resource}')", (error, response) =>
      @returnQueueId(response['insertId'])
    )
  
  returnQueueId: (qid) ->
    dbc.query("SELECT queue.id, queue.resource, players.jid FROM queue, players WHERE queue.id = #{qid} AND players.id = queue.user_id  LIMIT 1", (error, response) =>
      queueInformation = response[0]
      
      @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': "#{queueInformation['jid']}/#{queueInformation['resource']}"})
        .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
        .c('queueing', {'action': 'success'}).up()
        .c('queue', {'id': queueInformation['id']})
    )
    
#-----------------------------------------------------------------------------#

client = new xmpp.Client({jid: process.env.PLAYER_JID, password: process.env.PLAYER_PASSWORD})
mm = new MatchMaker(client)

#-----------------------------------------------------------------------------#

client.on 'online', ->
  mm.showReadyStatus()

client.on 'stanza', (stanza) -> 
  mm.handleStanza(stanza)  
