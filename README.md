

# Orca P4 Docs
> For p4app documentations refer to https://github.com/p4lang/p4app.

At the current stage, we think implementation of Orca logic on both spine and leaf (and core) would be straightforward. The current version of P4 codes contains a sketch solution (compilable) for both switches. 

The problem is that multicast functionality in P4 heavily relies on tables that are only manageable by the control plane.

Main challenges for realizing Orca (or any source-routed multicast) on programmable switches would be:
1. Exposing output port bitmaps to the processing pipelines
2. Allowing packet replication engine to replicate based on the bitmaps.
3. Hardware-specific considerations for the efficiency of processing (E.g Orca Spine per-link operations).

**Contents**
- [Details of current codes](#details-of-current-codes)
  * [Headers](#headers)
  * [Leaf Switch](#leaf-switch)
    + [Parsing headers](#parsing-headers)
    + [Processing packets](#processing-packets)
    + [Control plane](#control-plane)
  * [Spine switch](#spine-switch)
    + [Register arrays](#register-arrays)
    + [Processing packets](#processing-packets-1)
- [Limitations and considerations](#limitations-and-considerations)
  * [Previous works and possible workarounds](#previous-works-and-possible-workarounds)
    + [Elmo using Mellanox ASIC](#elmo-using-mellanox-asic)
    + [Using "clone" primitive (recirculation)](#using-clone-primitive-recirculation)
    + [Broadcast to egress pipeline](#broadcast-to-egress-pipeline)
  * [Hardware-Specific Considerations](#hardware-specific-considerations)
- [Implementing portmap extern function in software target](#implementing-portmap-extern-function-in-software-target)
  * [Examples of defining an extern function](#examples-of-defining-an-extern-function)
  * [What needs to be modified?](#what-needs-to-be-modified?)
    + [targets/simple_switch/simple_switch.cpp](#targetssimple_switchsimple_switchcpp)
    + [src/bm_sim/simple_pre.cpp:](#srcbm_simsimple_precpp)

## Details of current codes
### Headers
Current version assumes two headers: (1) Ethernet and (2) Orca headers. 
> Conventional headers can be added as well, here we only show how Orca packet processing works.

Ethernet headers:
* dstAddr: is used as session address.

Orca header stack:
* orca_status_label_t: Contains 1 bit leaf status + 7 bit packet type.
* src_label_t: contains labels that were attached by multicast source.
* leaf_label_t contains labels attached by agent inside each rack (only processed by leaf switch).
 

### Leaf Switch
The preliminary implementation of the leaf switch is available  in ``p4app/examples/orca_leaf``.

#### Parsing headers
When a packet arrives at the leaf switch it contains either *src_label_t* or *leaf_label_t* headers.  We define a header union orca_label_t which indicates one of these headers is valid for any packet arriving.

The parser will extract the *orca_status_label* and based on the *leaf_status_bit* it decides that the packet should contain *src_label* or *leaf_label* and extract the correct header.

####  Processing packets
After completion of parser stage, the switch will make decisions based on the headers:
 ```
If packet contains *src_label*
	 If it is coming from a spine link:
			Match on the leaf_status_bit and forwards the packet
			to the active agent port (given by control plane).

	If it is coming from a server link:
		 Forward the packet on upstream links 
		 (given by leaf_us label).

Else if packet contains *leaf_label*:
	Forward packet on downstream links (given by leaf_label).
```


#### Control plane 
> Only control plane functionality for  packet forwarding was implemented. Additional commands will be needed for exchanging health check packets between data plane and control plane.

Example control plane commands are written in `p4app/examples/orca_leaf/orca_leaf.config`.

In general the format for specifying commands is:
```table_add <table_name> <action_name> <match_value> => <action_data> ```


Leaf switch exposes the table *forward_agent* table (with *set_agent_port* action) and the *action_data* is the port number for active agent. 

### Spine switch
Parsing headers is similar to leaf switch.
- [**Slides on bloom filter implementation.**](https://adv-net.ethz.ch/pdfs/03_stateful.pdf)
#### Register arrays
```
// Maintains downstream linkIDs connected to the switch 
    register<bit<LINK_ID_BITS>>(NUM_SPINE_DS) link_ids;

// Maintains filter bitstrings for each downtream link connected to switch
    register<bit<32>>(NUM_SPINE_DS) link_bitstrings;

// In case of linkID change, switch can compute new hashes and update filters
    register<bit<1>>(1) compute_filter;
```
> To enable the switch to calculate  new bitstrings for a given linkID,  we use *compute_filter* bit. This is settable from control plane and in case it is set the P4 will compute a new filter bitstring for the given linkIDs. 
> **Currently, seems unnecessary as bitstrings can be passed directly by ctrl plane.**

#### Processing packets
For packets arriving from a leaf switch, spine will forward them on ports given by spine_us using *output_port_select()*.

For packets arriving from a core switch:
For each link connected to the switch, if it was included in the common label, it will replicate the packet on that link/port. Otherwise, it will check the bitwise AND between <link bitstring (from register arrays)> and <spine_ds\> label and  if the result is the same as bitstring packet will be replicated on that link.

## Limitations and considerations

**Multicast forwarding using bitmaps:**
Using labels (bitmaps) for multicast forwarding could be challenging with current P4 primitives.
The output port of a packet can be selected by setting "standard_metadata.egress_spec" which is a single port number. 

The default multicast functionality in P4 is implemented using "standard_metadata.mcast_grp" where a multicast group ID can map to multiple output ports (populated by ctrl plane), and the packet replication engine will handle the replication for multiple ports.


### Previous works and possible workarounds
Elmo implementation needs this primitive as well. It seems like their  [P4 repo](https://github.com/Elmo-MCast/p4-programs/blob/ccbe44c9498c149a2a68c2f36a015c4c52317add/elmo_spine_switch.p4)  are just example codes (not a functional, working code). 

Here in the  [first author's Ph.D. thesis](https://mshahbaz.gitlab.io/files/dissertation.pdf)  (sec. 3.5.1.2) they state that "We add support for specifying this bit vector using a new primitive action in P4.". But it seems for that primitive function they have another isolated design/experiment for ASIC implementation.

#### Elmo using Mellanox ASIC 
Presentation (does not include the details):
https://www.youtube.com/watch?v=uaY2dGS1dgs.

Report: 
https://mshahbaz.gitlab.io/files/p4summit20-elmo.pdf

#### Using "clone" primitive (recirculation)
Another way to implement the bitmap multicast forwarding is using the standard primitive ["clone_ingress_pkt_to_ingress" ](https://p4.org/p4-spec/p4-14/v1.0.5/tex/p4.pdf). 

We can use if statements at the ingress (apply{}) to extract the port mappings from the labels (using arithmetic operations) and then set the "egress_spec" for the output port of each replicated packet.

Clone primitive can be used for implementing multicast. But the clone is meant to be performed one-time only for each packet. So in order to realize multicast, one would need to:
 1. Clone an instance of pkt from ingress to the egress 
 2. Resubmit the original packet to the ingress pipline for the next output port.

Which hurts the performance as the number of output ports increases.

In a recent work, for implementing BIER multicast:
https://www.ietf.org/proceedings/108/slides/slides-108-bier-05-bier-in-p4-00

> Also, output port of a clone (similar to multicast group id) can be decided via mirror_session_id which is only manageable by the control plane so it won't work for our case.


#### Broadcast to egress pipeline
One option that would work with current limitations would be to use a dummy multicast group that contains all of the output ports so N pkts will be replicated by the replication engine (PRE) and then drop the undesired ones at the egress pipeline based on the label. Which I think comes with a performance penalty.

### Hardware-Specific Considerations
*How logical operations written in P4 are mapped to low-level gates in hardware and how it affects the performance?*

We need to perform some (simple) operations for every downstream link. For example, spine could process each port independently and in parallel in a handful of clock cycles.

Example of previous works:
 Containing complex nested operations:
They perform 8 match-actions for handling decisions based on bitmap in [NetCache](https://github.com/dlekkas/netcache/blob/master/src/p4/core/ingress.p4).
NetCache is able to do all of them at line rate.

## Implementing portmap extern function in software target
> This would help us to develop, run and test our P4 programs on software switch. But even with the software support for bitmap forwarding, it does not mean that hardware that supports BMv2 would support this function.

Note that p4app image is built on top of multiple p4-related images. We need to rebuild "p4lang/behavioral-model" after modifications:
 ```
 p4lang/p4app -> p4lang/p4c -> p4lang/behavioral-model -> p4lang/pi -> p4lang/third-party -> ubuntu:16.04
 ```

### Examples of defining an extern function
These are the related issues I could find for extern implementation:
* [https://github.com/p4lang/behavioral-model/issues/803](https://github.com/p4lang/behavioral-model/issues/803)  
* [https://github.com/p4lang/behavioral-model/issues/697](https://github.com/p4lang/behavioral-model/issues/697)  

It seems like after implementing the logic, using "BM_REGISTER_EXTERN()"  macros from behaviral_model repo ("bm/bm_sim/extern.h") one can add the extern name so that p4 compiler recognizes the extern function.

* Working extern function example (PSA target):
https://github.com/p4lang/behavioral-model/blob/master/targets/psa_switch/externs/psa_counter.h

* **Steps for adding extern** :[https://github.com/p4lang/behavioral-model/pull/834/files](https://github.com/p4lang/behavioral-model/pull/834/files)

---

### What needs to be modified?

#### targets/simple_switch/simple_switch.cpp
This is where ingress and egress packet processing is implemented.
The default multicast is implemented using mgid (multicast group ID) [@line 604].
The multicast() function [@line 455] uses PRE (packet replication engine [section 7.3](https://p4.org/p4-spec/docs/PSA.pdf)) to handle replication and puts each copy on egress.

#### src/bm_sim/simple_pre.cpp:
This is where packet replication is handled and it only exposes replicate() function to the data plane (simple_switch.cpp).
The replicate() [@line 269] function also decides the egress port_id (form of 0,1,2).

Apparently, the internal data structure for output ports inside PRE is in form of portmap [@line286], but they use the set bits in the map and convert them to port_id list.

The problem is at the end of the pipeline [simple_switch.cpp @line385], egress_port is used for transmitting packet so any portmap can not be used at the end of the pipeline.

--- 

A feasible solution might be to change the codes in simple_pre.cpp [@line286], to use our input bitmap (orca labels) to generate the port_ids instead of using l2_entry.port_map. Because  l2_entry.port_map  is generated based on processing mcast group entries and we already have this port map as our label.

However, I think this is not acceptable to modify the PRE as they mention that this part of the pipeline is not programmable in PSA.

## Running instructions
1.  Install  [docker](https://docs.docker.com/engine/installation/).
2. 
```
git clone https://github.com/parhamyassini/p4app.git
cd p4app
cp p4app /usr/local/bin
p4app run examples/simple_router.p4app
p4app build examples/orca_leaf
p4app run examples/orca_leaf
```
