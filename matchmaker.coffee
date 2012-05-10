xmpp = require('node-xmpp')

client = new xmpp.Client({jid: process.env.PLAYER_JID, password: process.env.PLAYER_PASSWORD})

client.on 'online', ->
  update_status()

client.on 'stanza', (stanza) -> 
  if stanza.attrs.type != 'error'
    switch stanza.name
      when 'message'
        process_message stanza

update_status = ->
  client.send new xmpp.Element('presence', {})
    .c('show').t('chat').up()
    .c('status').t('The matchmaker is ready!').up()
    .c('priority').t('0')

process_message = (stanza) ->
  # todo. (right now, just throw back everything)
  stanza.attrs.to = stanza.attrs.from
  delete stanza.attrs.from
  client.send stanza
