# OpenStreetMap data processing
I keep a copy of OSM downloaded because it's one of those datasets that's just
useful for a lot of different stuff. You have a couple of format options, XML
and ProtoBuf, and I download in XML because it requires less custom code to
process.

## Very first order of business: transcode bzip to lz4
bzip2's decompression speed is ~20MB/s/core, whereas LZ4 runs at about 400MB/s.
This is a huge difference when we're doing multiple scans over the XML.

```sh
$ ni osm-planet.bz2 z4\>osm-planet.lz4
```

## Nodes and ways
Most of what I care about is bound up in two types of objects, nodes and ways. A
node stores a physical location and a way links multiple nodes together to form
roads, buildings, and other stuff. These are normally stored in two large blocks
in the XML download.

First, let's pull out the nodes as TSV `nodeID lat lng`:

```sh
$ ni osm-planet.lz4 \
     S12r/\<node/p'r /id="([^"]+)"/, /lat="([^"]+)"/, /lon="([^"]+)"/' \
     z4\>osm-nodes.lz4
```

Next up, let's also pull ways as XML. The motivation here is that they're more
than 50GB into the file, so we can more quickly iterate on the parser if we have
them in their own file.

Sadly we can't scale this out; ways are multiline constructs, so we have to
serialize through a single perl process. This slows us down by about 8x, but we
can optimize a bit by using `egrep` to cut through non-ways (7x speedup) and by
bypassing ni's row-processing machinery for the ways themselves (3x speedup in
this case).

```sh
# compact way, about 50MB/s:
$ ni osm-planet.lz4 rp'/<way/../<\/way/' z4\>osm-ways.lz4

# fast way, about 160MB/s:
$ ni osm-planet.lz4 e[egrep -v '<node|</?changeset'] \
                    e[perl -ne 'print if /<way/../<\/way/'] \
     z4\>osm-ways.lz4

# let's also unpack relations, just so we have them:
$ ni osm-planet.lz4 e[egrep -v '<node|</?changeset'] \
                    e[perl -ne 'print if /<relation/../<\/relation/'] \
     z4\>osm-relations.lz4
```

### Processing ways
OK, we've got the ways as XML and they look like this:

```
 <way id="2953419" timestamp="2006-08-18T01:39:34Z" version="1" changeset="85894" user="robert" uid="1295">
  <nd ref="13796944"/>
  <nd ref="13796945"/>
  <nd ref="13796946"/>
  <tag k="highway" v="service"/>
  <tag k="created_by" v="JOSM"/>
 </way>
```

We need to dereference `<nd>` elements to their corresponding coordinates, which
we can do with one of two strategies:

1. Sort everything and do a streaming join
2. Load the full node list into memory and do an unsorted join

I think I have enough memory to do (2), but I'll want to pack the node list by
geohashing stuff and using a binary encoding. Before I get to this, though,
let's talk about general formatting.

#### Way format
We'll want to end up with a structured format for these things, which I think
can be this:

```
{attribute-json} {tag-json} node1 node2 ...
```

We can pack a way pretty easily:

```sh
$ ni osm-ways.lz4 p'my %attrs = /(\w+)="([^"]*)"/g;
                    my @ls    = ru{/<way/};
                    my @nodes = map /nd ref="(\d+)"/, @ls;
                    my %tags  = map /tag k="([^"]*)" v="([^"]*)"/, @ls;
                    r json_encode \%attrs,
                      json_encode \%tags,
                      @nodes' r5

{"changeset":29009974,"id":37,"timestamp":"2015-02-21T22:17:37Z","uid":2489541,"user":"PmaiIkeey","version":21} {"abutters":"residential","gritting":"priority_3","highway":"residential","is_in":"Sutton Coldfield","maintenance":"gritting","maxspeed":"30 mph","name":"Maney Hill Road","note":"gritting addition Oct 2010","postal_code":"B72"}     200511  1025338193      177231081       177081428       1025338209      177081440       200512  1025338201      200514  1025338210      200517  1025338191      200515  200526  200527  200528  200530  1082909509      1082909488      200532  200533  1082909478      1082909485      200534  1082909513      200535  1082909475      200536  1082909486      200537  200539  200541  1082909501      200540  200543  200542  3364627862      200544  3364604949      2715159904
{"changeset":20991637,"id":38,"timestamp":"2014-03-08T18:12:44Z","uid":133272,"user":"wongataa","version":5}    {"bicycle":"no","highway":"footway","is_in":"Sutton Coldfield","surface":"paved"}       200651  273776  273777  273778  273779  1026329587      273780  1026329626      1026329435      273781  273782
{"changeset":21461939,"id":41,"timestamp":"2014-04-02T17:09:47Z","uid":735,"user":"blackadder","version":7}     {"abutters":"residential","highway":"residential","incline":"-6.9%","is_in":"Sutton Coldfield","maxspeed":"30 mph","name":"Rowan Road","postal_code":"B72"}     200541  2715159905      200575  180180789       200576
{"changeset":21461939,"id":42,"timestamp":"2014-04-02T17:09:43Z","uid":735,"user":"blackadder","version":8}     {"abutters":"residential","highway":"residential","incline":"-6.1%","is_in":"Sutton Coldfield","maxspeed":"30 mph","name":"Elms Road","postal_code":"B72"}      200512  175923349       200601
{"changeset":21461939,"id":45,"timestamp":"2014-04-02T17:09:43Z","uid":735,"user":"blackadder","version":7}     {"abutters":"residential","highway":"residential","incline":"-13%","is_in":"Sutton Coldfield","maxspeed":"30 mph","name":"Douglas Road","postal_code":"B72"}    200532  2280525801
```

#### The node/way join
We'll want to get a bit creative by using a packed binary encoding and binary
splits to find elements. This is a bit slower than Perl datastructures, but uses
less than 10% of the space and saves us from having to sort the way list twice.
Counting up the rows:

```sh
$ ni osm-nodes.lz4 e'wc -l'
4254954891

$ units -t '4254954891 * 16bytes' GB    # how much memory do we need?
68.079278
```

Awesome, now let's generate the table. This is going to take a while.

```sh
$ ni osm-nodes.lz4 S24p'r a, ghe b, c, -60' \
     ^{row/sort-buffer=131072M row/sort-parallel=24} \
     op'wp"QQ", a, b' z\>osm-nodes-packed.QQ
```
