part of irc;

/**
 * IRC Client is the most important class in irc.dart
 *
 *      var config = new BotConfig(
 *        nickname: "DartBot",
 *        host: "irc.esper.net",
 *        port: 6667
 *      );
 *      var client = new Client(config);
 *      // Use Client
 */
class Client extends ClientBase with EventDispatcher {
  BotConfig config;

  /**
   * Channels that the Client is in.
   */
  List<Channel> channels = [];

  /**
   * WHOIS Implementation Builder Storage
   */
  Map<String, WhoisBuilder> _whois_builders;

  /**
   * Socket used for Communication between server and client
   */
  Socket _socket;

  /**
   * Flag for if the Client has sent a ReadyEvent
   */
  bool _ready = false;

  /**
   * Flag for if the Client has received any data from the server yet
   */
  bool _receivedAny = false;

  /**
   * Privately Stored Nickname
   */
  String _nickname;

  /**
   * The Client's Nickname
   */
  String get nickname => _nickname;

  /**
   * Flag for if the Client has hit an error.
   */
  bool _errored = false;

  /**
   * The IRC Parser to use.
   */
  final IrcParser parser;

  /**
   * Flag for if the Client is connected.
   */
  bool connected = false;

  /**
   * Storage for any data.
   * This will persist when you connect and disconnect.
   */
  final Map<String, dynamic> metadata;

  /**
   * Stores the MOTD
   */
  String _motd = "";

  /**
   * Gets the Server's MOTD
   * Not Ready until the ReadyEvent is posted
   */
  String get motd => _motd;

  /**
   * Creates a new IRC Client using the specified configuration
   * If parser is specified, then the parser is used for the current client
   */
  Client(BotConfig config, [IrcParser parser])
      : this.parser = parser == null ? new RegexIrcParser() : parser,
        this.metadata = {} {
    this.config = config;
    _registerHandlers();
    _nickname = config.nickname;
    _whois_builders = new Map<String, WhoisBuilder>();
  }

  /**
   * Registers all the default handlers.
   */
  void _registerHandlers() {
    register((LineReceiveEvent event) {

      /* Send initial information after we receive the first line */
      if (!_receivedAny) {
        _receivedAny = true;
        send("NICK ${config.nickname}");
        send("USER ${config.username} 8 * :${config.realname}");
      }

      /* Parse the IRC Input */
      var input = parser.convert(event.line);

      switch (input.command) {
        case "376": // End of MOTD
          post(new MOTDEvent(this, _motd));
          _fire_ready();
          break;

        case "PING":
          /* Server Ping */
          send("PONG :${input.message}");
          break;

        case "JOIN": // User Joined Channel
          var who = input.hostmask.nickname;
          var chan_name = input.parameters[0];
          if (who == _nickname) {
            // We Joined a New Channel
            if (channel(chan_name) == null) {
              channels.add(new Channel(this, chan_name));
            }
            post(new BotJoinEvent(this, channel(chan_name)));
            channel(chan_name).reload_bans();
          } else {
            post(new JoinEvent(this, who, channel(chan_name)));
          }
          break;

        case "PRIVMSG": // Message
          var from = input.hostmask.nickname;
          var target = input.parameters[0];
          var message = input.message;

          if (message.startsWith("\u0001")) {
            post(new CTCPEvent(this, from, target, message.substring(1, message.length - 1)));
          } else {
            post(new MessageEvent(this, from, target, message));
          }
          break;

        case "NOTICE":
          var from = input.plain_hostmask;
          if (input.parameters[0] != "*") from = input.hostmask.nickname;

          var target = input.parameters[0];
          var message = input.message;
          post(new NoticeEvent(this, from, target, message));
          break;

        case "PART": // User Left Channel
          var who = input.hostmask.nickname;

          var chan_name = input.parameters[0];

          if (who == _nickname) {
            post(new BotPartEvent(this, channel(chan_name)));
          } else {
            post(new PartEvent(this, who, channel(chan_name)));
          }
          break;

        case "QUIT": // User Quit
          var who = input.hostmask.nickname;

          if (who == _nickname) {
            post(new DisconnectEvent(this));
          } else {
            post(new QuitEvent(this, who));
          }
          break;

        case "332": // Topic
          var topic = input.message;
          var chan = channel(input.parameters[1]);
          chan._topic = topic;
          post(new TopicEvent(this, chan, topic));
          break;

        case "ERROR": // Server Error
          var message = input.message;
          post(new ErrorEvent(this, message: message, type: "server"));
          break;

        case "353": // Channel List
          var users = input.message.split(" ");
          var channel = this.channel(input.parameters[2]);

          users.forEach((user) {
            switch (user[0]) {
              case "@":
                channel.ops.add(user.substring(1));
                break;
              case "+":
                channel.voices.add(user.substring(1));
                break;
              default:
                channel.members.add(user);
                break;
            }
          });
          break;

        case "433": // Nickname is in Use
          var original = input.parameters[0];
          post(new NickInUseEvent(this, original));
          break;

        case "NICK": // Nickname Changed
          var original = input.hostmask.nickname;
          var now = input.message;

          /* Posts the Nickname Change Event. No need for checking if we are the original nickname. */
          post(new NickChangeEvent(this, original, now));
          break;

        case "MODE": // Mode Changed
          var split = input.parameters;

          if (split.length < 3) {
            break;
          }

          var channel = this.channel(split[0]);
          var mode = split[1];
          var who = split[2];

          if (mode == "+b" || mode == "-b") {
            channel.reload_bans();
          }

          post(new ModeEvent(this, mode, who, channel));
          break;

        case "311": // Beginning of WHOIS
          var split = input.parameters;
          var nickname = split[1];
          var hostname = split[3];
          var realname = input.message;
          var builder = new WhoisBuilder(nickname);
          builder
              ..hostname = hostname
              ..realname = realname;
          _whois_builders[nickname] = builder;
          break;

        case "312": // WHOIS Server Information
          var split = input.parameters;
          var nickname = split[1];
          var message = input.message;
          var server_name = split[2];
          var builder = _whois_builders[nickname];
          builder.server_name = server_name;
          builder.server_info = message;
          break;

        case "313": // WHOIS Operator Information
          var nickname = input.parameters[0];
          var builder = _whois_builders[nickname];
          builder.server_operator = true;
          break;

        case "317": // WHOIS Idle Information
          var split = input.parameters;
          var nickname = split[1];
          var idle = int.parse(split[2]);
          var builder = _whois_builders[nickname];
          builder.idle = true;
          builder.idle_time = idle;
          break;

        case "318": // End of WHOIS
          var nickname = input.parameters[1];
          var builder = _whois_builders.remove(nickname);
          post(new WhoisEvent(this, builder));
          break;

        case "319": // WHOIS Channel Information
          var nickname = input.parameters[1];
          var message = input.message.trim();
          var builder = _whois_builders[nickname];
          message.split(" ").forEach((chan) {
            if (chan.startsWith("@")) {
              var c = chan.substring(1);
              builder.channels.add(c);
              builder.op_in.add(c);
            } else if (chan.startsWith("+")) {
              var c = chan.substring(1);
              builder.channels.add(c);
              builder.voice_in.add(c);
            } else {
              builder.channels.add(chan);
            }
          });
          break;

        case "330": // WHOIS Account Information
          var split = input.parameters;
          var builder = _whois_builders[split[1]];
          builder.username = split[2];
          break;

        case "PONG": // PONG from Server
          var message = input.message;
          post(new PongEvent(this, message));
          break;

        case "367": // Ban List Entry
          var channel = this.channel(input.parameters[1]);
          if (channel == null) { // We Were Banned
            break;
          }
          var ban = input.parameters[2];
          channel.bans.add(new GlobHostmask(ban));
          break;

        case "KICK": // A User was kicked from a Channel
          var channel = this.channel(input.parameters[0]);
          var user = input.parameters[1];
          var reason = input.message;
          var by = input.hostmask.nickname;
          post(new KickEvent(this, channel, user, by, reason));
          break;
        case "372":
          var part = input.message;
          _motd += part + "\n";
          break;
        case "005":
          var params = input.parameters;
          params.removeAt(0);
          var message = params.join(" ");
          post(new ServerSupportsEvent(this, message));
          break;
      }

      /* Set the Connection Status */
      register((ConnectEvent event) => connected = true);
      register((DisconnectEvent event) => connected = false);

      /* Handles when the user quits */
      register((QuitEvent event) {
        for (var chan in channels) {
          chan.members.remove(event.user);
          chan.voices.remove(event.user);
          chan.ops.remove(event.user);
        }
      });

      /* Handles CTCP Events so the action event can be executed */
      register((CTCPEvent event) {
        if (event.message.startsWith("ACTION ")) {
          post(new ActionEvent(this, event.user, event.target, event.message.substring(7)));
        }
      });

      /* Handles User Tracking in Channels when a user joins. A user is a member until it is changed. */
      register((JoinEvent event) => event.channel.members.add(event.user));

      /* Handles User Tracking in Channels when a user leaves */
      register((PartEvent event) {
        var channel = event.channel;
        channel.members.remove(event.user);
        channel.voices.remove(event.user);
        channel.ops.remove(event.user);
      });

      /* Handles User Tracking in Channels when a user is kicked. */
      register((KickEvent event) {
        var channel = event.channel;
        channel.members.remove(event.user);
        channel.voices.remove(event.user);
        channel.ops.remove(event.user);
        if (event.user == nickname) {
          channels.remove(channel);
        }
      });

      /* Handles Nickname Changes */
      register((NickChangeEvent event) {
        if (event.original == _nickname) {
          _nickname = event.now;
        } else {
          for (Channel channel in channels) {
            if (channel.allUsers.contains(event.original)) {
              var old = event.original;
              var now = event.now;
              if (channel.members.contains(old)) {
                channel.members.remove(old);
                channel.members.add(now);
              }
              if (channel.voices.contains(old)) {
                channel.voices.remove(old);
                channel.voices.add(now);
              }
              if (channel.ops.contains(old)) {
                channel.ops.remove(old);
                channel.ops.add(now);
              }
            }
          }
        }
      });

      /* Handles Channel User Tracking */
      register((ModeEvent event) {
        if (event.channel != null) {
          var channel = event.channel;
          switch (event.mode) {
            case "+o":
              channel.ops.add(event.user);
              channel.members.remove(event.user);
              break;
            case "+v":
              channel.voices.add(event.user);
              channel.members.remove(event.user);
              break;
            case "-v":
              channel.voices.remove(event.user);
              channel.members.add(event.user);
              break;
            case "-o":
              channel.ops.remove(event.user);
              channel.members.add(event.user);
              break;
          }
        }
      });
    });

    /* When the Bot leaves a channel, we no longer retain the object. */
    register((BotPartEvent event) => channels.remove(event.channel));
  }

  /**
   * Fires the Ready Event if it hasn't been fired yet.
   */
  void _fire_ready() {
    if (!_ready) {
      _ready = true;
      post(new ReadyEvent(this));
    }
  }

  /**
   * Connects to the IRC Server
   * Any errors are sent through the [ErrorEvent].
   */
  void connect() {
    Socket.connect(config.host, config.port).then((Socket sock) {
      _socket = sock;

      runZoned(() {
        post(new ConnectEvent(this));

        sock.handleError((err) {
          post(new ErrorEvent(this, err: err, type: "socket"));
        }).transform(new Utf8Decoder(allowMalformed: true)).transform(new LineSplitter()).listen((message) {
          post(new LineReceiveEvent(this, message));
        });
      }, onError: (err) => post(new ErrorEvent(this, err: err, type: "socket-zone")));
    });
  }

  /**
   * Sends the [message] to the [target] as a message.
   *
   *      client.message("ExampleUser", "Hello World");
   *
   * Note that this handles long messages. If the length of the message is 454
   * characters or bigger, it will split it up into multiple messages
   */
  void message(String target, String message) {
    var begin = "PRIVMSG ${target} :";

    var all = _handle_message_sending(begin, message);

    for (String msg in all) {
      send(begin + msg);
    }
  }

  /**
   * Splits the Messages if required.
   *
   * [begin] is the very beginning of the line (like 'PRIVMSG user :')
   * [input] is the message
   */
  List<String> _handle_message_sending(String begin, String input) {
    var all = [];
    if ((input.length + begin.length) > 454) {
      var max_msg = 454 - (begin.length + 1);
      var sb = new StringBuffer();
      for (int i = 0; i < input.length; i++) {
        sb.write(input[i]);
        if ((i != 0 && (i % max_msg) == 0) || i == input.length - 1) {
          all.add(sb.toString());
          sb.clear();
        }
      }
    } else {
      all = [input];
    }
    return all;
  }

  /**
   * Sends the [input] to the [target] as a notice
   *
   *      client.notice("ExampleUser", "Hello World");
   *
   * Note that this handles long messages. If the length of the message is 454
   * characters or bigger, it will split it up into multiple messages
   */
  void notice(String target, String message) {
    var begin = "NOTICE ${target} :";
    var all = _handle_message_sending(begin, message);
    for (String msg in all) {
      send(begin + msg);
    }
  }

  /**
   * Sends [line] to the server
   *
   *      client.send("WHOIS ExampleUser");
   *
   * Will throw an error if [line] is greater than 510 characters
   */
  void send(String line) {
    /* Max Line Length for IRC is 512. With the newlines (\r\n or \n) we can only send 510 character lines */
    if (line.length > 510) {
      post(new ErrorEvent(this, type: "general", message: "The length of '${line}' is greater than 510 characters"));
    }
    /* Sending the Line has Priority over the Event */
    _socket.writeln(line);
    post(new LineSentEvent(this, line));
  }

  /**
   * Joins the specified [channel].
   */
  void join(String channel) => send("JOIN ${channel}");

  /**
   * Parts the specified [channel].
   */
  void part(String channel) => send("PART ${channel}");

  /**
   * Gets a Channel object for the channel's [name].
   * Returns null if no such channel exists.
   */
  Channel channel(String name) => channels.firstWhere((channel) => channel.name == name, orElse: () => null);

  /**
   * Changes the Client's Nickname
   *
   * [nickname] is the nickname to change to
   */
  void changeNickname(String nickname) {
    send("NICK ${nickname}");
  }

  /**
   * Identifies the user with the [nickserv].
   *
   * the default [username] is your configured username.
   * the default [password] is password.
   * the default [nickserv] is NickServ.
   */
  void identify({String username: "PLEASE_INJECT_DEFAULT", String password: "password", String nickserv: "NickServ"}) {
    if (username == "PLEASE_INJECT_DEFAULT") {
      username = config.username;
    }
    message(nickserv, "identify ${username} ${password}");
  }

  /**
   * Disconnects the Client with the specified [reason].
   * If [force] is true, then the socket is forcibly closed.
   * When it is forcibly closed, a future is returned.
   */
  Future disconnect({String reason: "Client Disconnecting", bool force: false}) {
    send("QUIT :${reason}");
    if (force) {
      return _socket.close();
    }
    return null;
  }

  /**
   * Sends [msg] to [target] as an action.
   */
  void action(String target, String msg) => ctcp(target, "ACTION ${msg}");

  /**
   * Kicks [user] from [channel] with an optional [reason].
   */
  void kick(Channel channel, String user, [String reason]) {
    send("KICK ${channel.name} ${user}${reason != null ? ' :' + reason : ''}");
  }

  /**
   * Sends [msg] to [target] as a CTCP message
   */
  void ctcp(String target, String msg) => message(target, "\u0001${msg}\u0001");

  /**
   * Posts a Event to the Event Dispatching System
   * The purpose of this method was to assist in checking for Error Events.
   *
   * [event] is the event to post.
   */
  @override
  void post(Event event) {
    /* Handle Error Events */
    if (event is ErrorEvent) {
      _errored = true;
    }
    super.post(event);
  }
}
