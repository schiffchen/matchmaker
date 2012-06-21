###
Matchmaker
  This is it, the magic matchmaker. See the docs for further information

(c) 2012, Schiffchen Team <schiffchen@dsx.cc>

This server is designed to run on heroku. Therefore, we are using environment
variables to allow our deploying machine to set up the settings dynamically.

Used environment variables:
  DB_HOST       - The database host
  DB_USER       - The database user
  DB_PASSWORD   - Password for the database user
  DB_DATABASE   - Databases name
  XMPP_JID      - The full jabber-id for the matchmaker.
  XMPP_PASSWORD - The password for the matchmaker-jabber-account
###

#-----------------------------------------------------------------------------#

xmpp = require('node-xmpp')
mysql = require('mysql')

# Just a little helper to determinate if a string
# starts with something or not
if typeof String.prototype.startsWith != 'function'
  String.prototype.startsWith = (str) ->
    this.indexOf(str) == 0

# timestamp calculation in JS is ugly, so
# we need that little helper method here.
now_ts = ->
  Math.round((new Date()).getTime() / 1000)
  
log = (type, message) ->
  console.log("[#{new Date()}][#{type}] #{message}")

#-----------------------------------------------------------------------------#

###
  BasicBot
  
  A very basic bot class. Simply does nothing but saying something
  to someone
###
class BasicBot
  ###
    Constructor
  ###
  constructor: (@xmppClient) ->
  
  ###
    Say
    
    A method to send someone a message!
    
    Params:
      - to [String] The recipent
      - message [String] The message
  ###
  say: (to, message) ->
    @xmppClient.send new xmpp.Element('message', {'type': 'chat', 'to': to})
      .c('body').t(message)
      
#-----------------------------------------------------------------------------#

###
  MatchMaker
  
  Our matchmaker class handling everything
  
  Extends BasicBot
###
class MatchMaker extends BasicBot
  ###
    Constructor
    
    MatchMaker's constructor. The matchmaker as a queue-object and a statistic
    object which gets assigned in the constructor
  ###
  constructor: (@xmppClient) ->
    @queue = new Queue(@)
    @statistic = new Statistic(@)
    super(@xmppClient)
  
  ###
    showReadyStatus
    
    Show everyone we are ready to handle queueing requests
  ###
  showReadyStatus: ->
    @xmppClient.send new xmpp.Element('presence', {})
      .c('show').t('chat').up()
      .c('status').t('The matchmaker is ready!').up()
      .c('priority').t('0')
    
  ###
    showBusyStatus
    
    Is used to tell everyone we don't want to have new requests right
    now. Should be triggerd if there is too much load.
  ###
  showBusyStatus: ->
    @xmppClient.send new xmpp.Element('presence', {})
      .c('show').t('dnd').up()
      .c('status').t('Too busy right now, try again later.').up()
      .c('priority').t('0')

  ###
    handleStanza
    
    General handler for all incoming stanzas. This function should
    be set as handler for our XMPPClient
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
  ###
  handleStanza: (stanza) ->
    if stanza.attrs.type != 'error'
      switch stanza.name
        when 'message'
          if stanza.type == 'chat'
            @processCommand(stanza)
            
            # process actions here, too. That's not what we have defined
            # in our protocol, but it seems like some of the Android/Windows
            # Phone-libs have problems with type==normal.
            @processAction(stanza)
          else if stanza.type == 'normal'
            @processAction(stanza)

  ###
    processCommand
    
    Handler for command stanzas. Just fires the functions to do further stuff
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
  ###
  processCommand: (stanza) ->
    body = stanza.getChild('body')
    if body
      message = body.getText()
      if message.startsWith('help')
        @help(stanza.from)
      else if message.startsWith('count players')
        dbc.query('SELECT count(*) FROM players;', (error, response) =>
          if error
            log("mysql", error)
          else
            @say(stanza.from, "Okay! I found #{response[0]['count(*)']} players.")
        )
        
  ###
    processAction
    
    Handler for battleship-game related stanzas coming in
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
  ###
  processAction: (stanza) ->
    battleship = stanza.getChild('battleship')
    if battleship
      if queueing = battleship.getChild('queueing')
        if queueing.attrs.action == 'request'
          @queue.enqueueUser(stanza)
        if queueing.attrs.action == 'ping'
          @queue.pingQueue(stanza, queueing)
      else if result = battleship.getChild('result')
        @statistic.track(stanza, result)
           
  ###
    help
    
    Just returns a little man page.
    
    Params:
      - to [String] The recipiant for the help
  ###
  help: (to) ->
    @say(to, """You wanna help? Here you are:
      help - Shows this message
      count players - Counts all players in the database""")

#-----------------------------------------------------------------------------#

###
  Queue
  
  The class handling everything regarding the queue: Enqueueing, timeouts
  and assigning
###
class Queue
  ###
    Constructor
  ###
  constructor: (mm) ->
    @mm = mm
        
  ###
    enqueueUser
    
    Prepare a queueing request for adding it to the queue
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
  ###
  enqueueUser: (stanza) ->
    jidParts = stanza.from.split('/')
    id = 0

    dbc.query("SELECT id FROM players WHERE jid='#{jidParts[0]}' LIMIT 1", (error, response) =>
      if error
        log("mysql", error)
      if response[0]
        id = response[0]['id']
        @addToQueue(id, jidParts[1])
      else
        dbc.query("INSERT INTO players (jid) VALUES ('#{jidParts[0]}');
          SELECT id FROM players WHERE jid='#{jidParts[0]}' LIMIT 1", (error, response) => 
          if error
            log("mysql", error)
          else
            @addToQueue(response['insertId'], jidParts[1])
        )
    )
    
  ###
    addToQueue
    
    Add the user/resource to the queue.
    
    Params:
      - uid [Integer] The UID of the enqueueing user
      - resource [String] User's resource
  ###
  addToQueue: (uid, resource) ->
    # ToDo: Handle duplicate queue entries
    dbc.query("INSERT INTO queue (queued_at, user_id, resource) VALUES (#{now_ts()}, #{uid}, '#{resource}')", (error, response) =>
      if error
        log("mysql", error)
      else
        @returnQueueId(response['insertId'])
        log("info", "Enqueued user##{uid}, resource: #{resource}, queue##{response['insertId']}.")
        @cleanupQueue()
    )
    @assignPlayers()
  
  ###
    returnQueueId
    
    Send the queueid to the user to confirm it's enqueueing
    
    Params:
      - qid [Integer] The queue id
  ###
  returnQueueId: (qid) ->
    dbc.query("SELECT queue.id, queue.resource, players.jid FROM queue, players WHERE queue.id = #{qid} AND players.id = queue.user_id  LIMIT 1", (error, response) =>
      if error
        log("mysql", error)
      else
        queueInformation = response[0]
        @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': "#{queueInformation['jid']}/#{queueInformation['resource']}"})
          .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
          .c('queueing', {'action': 'success', 'id': queueInformation['id']})
    )
  
  ###
    pingQueue
    
    Handle an incoming ping-request. Reset the timestamp to keep the
    queueing alive
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
      - queueing [XMLChild] The queueing part in the stanza
  ###
  pingQueue: (stanza, queueing) ->
    id = queueing.attrs.id
    dbc.query("UPDATE queue SET queued_at=#{now_ts()} WHERE id=#{id}", (error, response) =>
      if error
        log("mysql", error)
      else
        @confirmPing(stanza, queueing)
        log("info", "Updated timestamp of qid#{id} because I got a ping.")
        @cleanupQueue()
    )
    @assignPlayers()
    
  ###
    confirmPing
    
    Confirm a ping by sending it back to the client
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
      - queueing [XMLChild] The queueing part in the stanza
  ###
  confirmPing: (stanza, queueing) ->
    id = queueing.attrs.id
    @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': stanza.from})
      .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
      .c('queueing', {'action': 'ping', 'id': id})

  ###
    cleanupQueue
    
    Remove queue entries which are older than 30 seconds.
  ###
  cleanupQueue: ->
    expired = now_ts() - 30
    dbc.query("DELETE FROM queue WHERE queued_at <= #{expired}", (error, response) =>
      if error
        log("mysql", error)
      else
        log("info", "Deleted #{response.affectedRows} expired queue ids")
    )
    
  ###
    assignPlayers
    
    Checks if there are two matching players. If yes,
    assign them.
  ###
  assignPlayers: ->
    @cleanupQueue()
    dbc.query("SELECT count(*) FROM queue", (error, response) =>
      if error
        log("mysql", error)
      else
        queueCount = response[0]['count(*)']
        while queueCount >= 2
          dbc.query("SELECT queue.id, CONCAT(players.jid, '/', queue.resource) AS jid
                     FROM queue, players WHERE players.id=queue.user_id    
                     ORDER BY queue.queued_at ASC
                     LIMIT 2", (error, response) =>
            if error
              log("mysql", error)
            else
              # Assign the two players to each other
              if response.length == 2
                matchid = require('crypto').createHash('md5').update("#{now_ts()}#{response[0].jid}#{response[1].jid}").digest('hex');
            
                @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': response[0].jid})
                  .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
                  .c('queueing', {'action': 'assign', 'jid': response[1]['jid'], 'mid': matchid})
                @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': response[1].jid})
                  .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
                  .c('queueing', {'action': 'assign', 'jid': response[0]['jid'], 'mid': matchid})
              
                log("info", "Assigned #{response[0]['jid']} and #{response[1]['jid']}. Match: #{matchid}")
            
                # delete the queueing entry. maybe this should be done after confirmation
                # todo
                dbc.query("DELETE FROM queue WHERE id IN (#{response[0].id},#{response[1].id})")
              else
                log("info", "Tried to assign two players, but I got no jids :O")
          )
          queueCount -= 2;
    )
    
#-----------------------------------------------------------------------------#

###
  Statistic
  
  The class handling all statistical stuff
###
class Statistic
  ###
    Constructor
  ###
  constructor: (mm) ->
    @mm = mm
    
  ###
    Track
    
    This functions takes care of collecting statistics
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
      - result [XMLChild] The result part in the stanza
  ###
  track: (stanza, result) ->
    @insertOrPublish(stanza, result)
  
  ###
    insertOrPublish
    
    This function inserts a statisctical database entry or updates
    it if it already exists.
  
    Params:
      - stanza [XMPPStanza] The incoming stanza
      - result [XMLChild] The result part in the stanza
  ###
  insertOrPublish: (stanza, result) ->
    user = result.attrs.winner.split("/")[0]
    dbc.query("SELECT id FROM players WHERE jid='#{user}'", (error, response) =>
      userid = response[0]["id"]
      
      unless userid
        userid = 0
        
      dbc.query("SELECT id, public FROM statistics WHERE mid='#{result.attrs.mid}' LIMIT 1", (error, response) =>
        if error
          log("mysql", error)
        
        if response.length > 0
          if response[0]['public']
            @confirm(stanza, result)
          else
            dbc.query("UPDATE statistics SET public=1 WHERE id=#{response[0].id}", (error, response) =>
              if error
                log("mysql", error)  
            )
            @confirm(stanza, result)
        else
          dbc.query("INSERT INTO statistics (mid, winner_pid) VALUES (\"#{result.attrs.mid}\", #{userid})", (error, response) =>
            if error
              log("mysql", error)
          )
          @confirm(stanza, result)
      )
    )

  ###
    Confirm
    
    Confirm the incoming result
    
    Params:
      - stanza [XMPPStanza] The incoming stanza
      - result [XMLChild] The result part in the stanza
  ###
  confirm: (stanza, result) ->
    @mm.xmppClient.send new xmpp.Element('message', {'type': 'normal', 'to': stanza.from})
      .c('battleship', {'xmlns': 'http://battleship.me/xmlns/'})
      .c('result', {'status': 'saved', 'mid': result.attrs.mid, 'winner': result.attrs.winner})    

    
#-----------------------------------------------------------------------------#

# initiate the database and switch to it. Note: node-mysql has an automatic
# reconect mechanism, so we don't have to bother about that
dbc = mysql.createClient({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
})
dbc.query('USE ' + process.env.DB_DATABASE)

#-----------------------------------------------------------------------------#

client = new xmpp.Client({jid: process.env.XMPP_JID, password: process.env.XMPP_PASSWORD})
mm = new MatchMaker(client)

#-----------------------------------------------------------------------------#

client.on 'online', ->
  mm.showReadyStatus()

client.on 'stanza', (stanza) -> 
  mm.handleStanza(stanza)  
