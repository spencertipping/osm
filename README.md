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
     S12[r/\<node/p'r /id="([^"]+)"/, /lat="([^"]+)"/, /lon="([^"]+)"/'] \
     z4\>osm-nodes.lz4
```

Next up, let's also pull ways as XML. The motivation here is that they're more
than 50GB into the file, so we can more quickly iterate on the parser if we have
them in their own file.

Sadly we can't scale this out; ways are multiline constructs, so we have to
serialize through a single perl process. This slows us down by about 8x, but we
can optimize a bit by using `egrep` to cut through non-ways (5x speedup) and by
bypassing ni's row-processing machinery (3x speedup in this case).

```sh
# compact way, about 50MB/s:
$ ni osm-planet.lz4 rp'/<way/../<\/way/' z4\>osm-ways.lz4

# fast way, about 160MB/s:
$ ni osm-planet.lz4 e[egrep -v '<node|</?changeset|<tag'] \
                    e[perl -ne 'print if /<way/../<\/way/'] \
     z4\>osm-ways.lz4
```
