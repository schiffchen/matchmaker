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
  showReadyStatus: ->
    @xmppClient.send new xmpp.Element('presence', {})
      .c('show').t('chat').up()
      .c('status').t('The matchmaker is ready!').up()
      .c('priority').t('0')

  handleStanza: (stanza) ->
    if stanza.attrs.type != 'error'
      switch stanza.name
        when 'message'
          if stanza.type == 'chat'
            @processCommand(stanza)

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
      else
        @say(stanza.from, 'I am so sorry, I did not understand you! :-(')
  
  help: (to) ->
    @say(to, """You wanna help? Here you are:
      help - Shows this message
      count players - Counts all players in the database""")
    
#-----------------------------------------------------------------------------#

client = new xmpp.Client({jid: process.env.PLAYER_JID, password: process.env.PLAYER_PASSWORD})
mm = new MatchMaker(client)

#-----------------------------------------------------------------------------#

client.on 'online', ->
  mm.showReadyStatus()

client.on 'stanza', (stanza) -> 
  mm.handleStanza(stanza)  
