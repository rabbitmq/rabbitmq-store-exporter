**Repository [moved to GitHub](https://github.com/rabbitmq/rabbitmq-store-exporter)**.
This is a stale read-only repository.

RabbitMQ Store Exporter Plugin
==============================

This plugin exports from RabbitMQ's internal stores all the messages
it can find on disk.

The plugin must be installed and enabled, configured, and then Rabbit
must be restarted. Upon restart, the plugin will activate and will
export all messages it gets. After it is done, RabbitMQ will continue
to boot normally. The export process can take some time, and whilst it
is ongoing, RabbitMQ will not boot further.


Configuration
-------------

In your rabbitmq.config, you need to add an entry for
rabbitmq_store_exporter, specifying the directory to export messages
to. For example, you may end up with a complete config file like:

[
 {rabbit,                  [{hipe_compile, true}]},
 {rabbitmq_store_exporter, [{directory, "/backups/rabbitmq/exported"}]}
].

Once the plugin is enabled, RabbitMQ will export all messages out to
files beneath the directory "/backups/rabbitmq/exported".


Format
------

Within the export directory, the file layout is as follows:

dir/
  messages/
    $message_id/
      raw        - The exact bytes RabbitMQ internally stores the message as
      payload    - The exact bytes the client sent to RabbitMQ as the message
                     payload.
      properties - An Erlang term file which contains many properties
                     of the message including the exchange name to
                     which the message was published, the routing keys
                     the message was published with, amongst other
                     details. These details, together with the
                     payload, can be used to recreate the publication
                     of the message.
  queues/
    $queue_id/
      $sequence_number - The smaller the file number is, the closer
                     the corresponding message is to the head of the
                     queue. This file is also an Erlang term file, and
                     contains details of the message in its location
                     within the queue. The message_id is indicated
                     which can then be cross-referenced into the
                     messages directory. Also indicated is whether the
                     message has already been delivered, and whether
                     it has been acknowledged, along with other
                     properties such as queue-TTL, if in use.

      Note that the $queue_id cannot be used to compute the original
      queue name: the conversion from queue name to queue_id is lossy.


What is exported?
-----------------

This plugin exports all messages it can find. This can include
messages that have been already delivered and acknowledged by clients,
and no attempt is made to achieve consistency. For example, there may
be messages under the "messages" sub-directory, that are not
referenced by any queue. These are most likely messages that have been
delivered and acknowledged, but RabbitMQ has not yet run a garbage
collection sweep to remove such messages from disk.

Note that this plugin runs *before* non-durable queues are
deleted. Thus if a non-durable queue wrote messages to disk (possible
under memory contention), this plugin may be able to recover the
messages that were within such queues.

This plugin may create an awful lot of small files. Some filesystems
do not perform particularly well for such use cases and thus the
plugin may take a long time to run. There may also be a very large
amount of disk space used because filesystems tend to have a minimum
file size which may be substantially bigger than the files being
created by this plugin. Thus the amount of disk space taken up by the
files this plugin creates can be orders of magnitude more than the
amount of disk space RabbitMQ internally uses to store messages.
