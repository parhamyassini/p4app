#ifndef __HEADER_P4__
#define __HEADER_P4__ 1

#define NUM_SW_PORTS   48
#define NUM_LEAF_US    24
#define NUM_LEAF_DS    24
#define NUM_SPINE_DS   24
#define NUM_SPINE_US   24
#define NUM_CORE_DS    48
#define DEFAULT_AGENT_PORT   4

// Label (bitmap) to be used for multicast forwarding stored in metadata
struct portmap_metadata_t {
    bit<NUM_SW_PORTS> out_portmap;
}

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

// If set, extract leaf_us label
header orca_status_label_t {
    bit<7> orca_pkt_type;
    bit<1> leaf_status_bit;
}

// Used for upstream forwarding
header src_label_t {
    bit<NUM_LEAF_US>  leaf_us;
    bit<NUM_SPINE_US>  spine_us;
    bit<NUM_SPINE_DS> spine_ds;
    bit<NUM_CORE_DS> core_ds;
}

// Used for downstream forwarding
header leaf_label_t {
    bit<NUM_LEAF_DS> leaf_ds;
}

// Each Orca packet either contains orca_src_label or orca_leaf_label
header_union orca_label_t {
    src_label_t src_label;
    leaf_label_t leaf_label;
}

struct metadata {
    portmap_metadata_t   portmap_metadata;
}

struct headers {
    @name("ethernet")
    ethernet_t ethernet;
    @name("orca_status")
    orca_status_label_t orca_status;
    @name("orca_label")
    orca_label_t orca_label;
}

#endif // __HEADER_P4__
