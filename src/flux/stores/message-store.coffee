NylasStore = require "nylas-store"
Actions = require "../actions"
Message = require "../models/message"
Thread = require "../models/thread"
Utils = require '../models/utils'
DatabaseStore = require "./database-store"
NamespaceStore = require "./namespace-store"
FocusedContentStore = require "./focused-content-store"
ChangeUnreadTask = require '../tasks/change-unread-task'
NylasAPI = require '../nylas-api'
async = require 'async'
_ = require 'underscore'

class MessageStore extends NylasStore

  constructor: ->
    @_setStoreDefaults()
    @_registerListeners()

  ########### PUBLIC #####################################################

  items: ->
    @_items

  threadId: -> @_thread?.id

  thread: -> @_thread

  itemsExpandedState: =>
    # ensure that we're always serving up immutable objects.
    # this.state == nextState is always true if we modify objects in place.
    _.clone @_itemsExpanded

  itemLocalIds: =>
    _.clone @_itemsLocalIds

  itemsLoading: ->
    @_itemsLoading

  ###
  Message Store Extensions
  ###

  # Public: Returns the extensions registered with the MessageStore.
  extensions: =>
    @_extensions

  # Public: Registers a new extension with the MessageStore. MessageStore extensions
  # make it possible to customize message body parsing, and will do more in
  # the future.
  #
  # - `ext` A {MessageStoreExtension} instance.
  #
  registerExtension: (ext) =>
    @_extensions.push(ext)

  # Public: Unregisters the extension provided from the MessageStore.
  #
  # - `ext` A {MessageStoreExtension} instance.
  #
  unregisterExtension: (ext) =>
    @_extensions = _.without(@_extensions, ext)


  ########### PRIVATE ####################################################

  _setStoreDefaults: =>
    @_items = []
    @_itemsExpanded = {}
    @_itemsLocalIds = {}
    @_itemsLoading = false
    @_thread = null
    @_extensions = []
    @_inflight = {}

  _registerListeners: ->
    @listenTo DatabaseStore, @_onDataChanged
    @listenTo FocusedContentStore, @_onFocusChanged
    @listenTo Actions.toggleMessageIdExpanded, @_onToggleMessageIdExpanded

  _onDataChanged: (change) =>
    return unless @_thread

    if change.objectClass is Message.name
      inDisplayedThread = _.some change.objects, (obj) => obj.threadId is @_thread.id
      if inDisplayedThread
        @_fetchFromCache()

        # Are we most likely adding a new draft? If the item is a draft and we don't
        # have it's local Id, optimistically add it to the set, resort, and trigger.
        # Note: this can avoid 100msec+ of delay from "Reply" => composer onscreen,
        item = change.objects[0]
        if change.objects.length is 1 and item.draft is true and @_itemsLocalIds[item.id] is null
          DatabaseStore.localIdForModel(item).then (localId) =>
            @_itemsLocalIds[item.id] = localId
            @_items.push(item)
            @_items = @_sortItemsForDisplay(@_items)
            @trigger()

    if change.objectClass is Thread.name
      updatedThread = _.find change.objects, (obj) => obj.id is @_thread.id
      if updatedThread
        @_thread = updatedThread
        @_fetchFromCache()

  _onFocusChanged: (change) =>
    focused = FocusedContentStore.focused('thread')
    return if @_thread?.id is focused?.id

    @_thread = focused
    @_items = []
    @_itemsLoading = true
    @_itemsExpanded = {}
    @trigger()

    @_fetchFromCache()

  _onToggleMessageIdExpanded: (id) =>
    item = _.findWhere(@_items, {id})
    return unless item

    if @_itemsExpanded[id]
      delete @_itemsExpanded[id]
    else
      @_itemsExpanded[id] = "explicit"
      @_fetchExpandedBodies([item])
      @_fetchExpandedAttachments([item])
    @trigger()

  _fetchFromCache: (options = {}) ->
    return unless @_thread
    loadedThreadId = @_thread.id

    query = DatabaseStore.findAll(Message, threadId: loadedThreadId)
    query.include(Message.attributes.body)
    query.then (items) =>
      localIds = {}
      async.each items, (item, callback) ->
        return callback() unless item.draft
        DatabaseStore.localIdForModel(item).then (localId) ->
          localIds[item.id] = localId
          callback()
      , =>
        # Check to make sure that our thread is still the thread we were
        # loading items for. Necessary because this takes a while.
        return unless loadedThreadId is @_thread?.id

        loaded = true

        @_items = @_sortItemsForDisplay(items)
        @_itemsLocalIds = localIds

        # If no items were returned, attempt to load messages via the API. If items
        # are returned, this will trigger a refresh here.
        if @_items.length is 0
          @_fetchMessages()
          loaded = false

        @_expandItemsToDefault()

        # Download the attachments on expanded messages.
        @_fetchExpandedAttachments(@_items)

        # Check that expanded messages have bodies. We won't mark ourselves
        # as loaded until they're all available. Note that items can be manually
        # expanded so this logic must be separate from above.
        if @_fetchExpandedBodies(@_items)
          loaded = false

        # Normally, we would trigger often and let the view's
        # shouldComponentUpdate decide whether to re-render, but if we
        # know we're not ready, don't even bother.  Trigger once at start
        # and once when ready. Many third-party stores will observe
        # MessageStore and they'll be stupid and re-render constantly.
        if loaded
          # Mark the thread as read if necessary. Make sure it's still the
          # current thread after the timeout.

          # Override canBeUndone to return false so that we don't see undo prompts
          # (since this is a passive action vs. a user-triggered action.)
          if @_thread.unread
            markAsReadDelay = atom.config.get('core.reading.markAsReadDelay')
            setTimeout =>
              return unless loadedThreadId is @_thread?.id
              t = new ChangeUnreadTask(thread: @_thread, unread: false)
              t.canBeUndone = => false
              Actions.queueTask(t)
            , markAsReadDelay

          @_itemsLoading = false
          @trigger(@)

  _fetchExpandedBodies: (items) ->
    startedAFetch = false
    for item in items
      continue unless @_itemsExpanded[item.id]
      if not _.isString(item.body)
        @_fetchMessageIdFromAPI(item.id)
        startedAFetch = true
    startedAFetch

  _fetchExpandedAttachments: (items) ->
    return unless atom.config.get('core.attachments.downloadPolicy') is 'on-read'
    for item in items
      continue unless @_itemsExpanded[item.id]
      for file in item.files
        Actions.fetchFile(file)

  # Expand all unread messages, all drafts, and the last message
  _expandItemsToDefault: ->
    for item, idx in @_items
      if item.unread or item.draft or idx is @_items.length - 1
        @_itemsExpanded[item.id] = "default"

  _fetchMessages: ->
    namespace = NamespaceStore.current()
    NylasAPI.getCollection namespace.id, 'messages', {thread_id: @_thread.id}

  _fetchMessageIdFromAPI: (id) ->
    return if @_inflight[id]

    @_inflight[id] = true
    namespace = NamespaceStore.current()
    NylasAPI.makeRequest
      path: "/n/#{namespace.id}/messages/#{id}"
      returnsModel: true
      success: =>
        delete @_inflight[id]
      error: =>
        delete @_inflight[id]

  _sortItemsForDisplay: (items) ->
    # Re-sort items in the list so that drafts appear after the message that
    # they are in reply to, when possible. First, identify all the drafts
    # with a replyToMessageId and remove them
    itemsInReplyTo = []
    for item, index in items by -1
      if item.draft and item.replyToMessageId
        itemsInReplyTo.push(item)
        items.splice(index, 1)

    # For each item with the reply header, re-inset it into the list after
    # the message which it was in reply to. If we can't find it, put it at the end.
    for item in itemsInReplyTo
      for other, index in items
        if item.replyToMessageId is other.id
          items.splice(index+1, 0, item)
          item = null
          break
      if item
        items.push(item)

    items

module.exports = new MessageStore()
