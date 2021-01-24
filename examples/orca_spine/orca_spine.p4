#include <core.p4>
#include <v1model.p4>

#include "header.p4"
#include "parser.p4"

#define LINK_ID_BITS 16

control egress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    apply {
    }
}

//@noSideEffects
//extern void output_port_select(in bit<NUM_SW_PORTS> bitmap);// the extern action for bitmap-based port selection

control ingress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    
    //register<bit<1>>(32) new_bloom_filter;
    bit<32> new_bloom_filter;

    // Maintains downstream linkIDs connected to the switch 
    register<bit<LINK_ID_BITS>>(NUM_SPINE_DS) link_ids;

    // Maintains filter bitstrings for each downtream link connected to switch
    register<bit<32>>(NUM_SPINE_DS) link_bitstrings;

    // In case of linkID change, switch can compute new hashes and update filters
    register<bit<1>>(1) compute_filter;

    bit<NUM_SPINE_DS> session_state;
    action _drop() {
        mark_to_drop(standard_metadata);
    }

    action forward_downstream() {
        // US ports are 0, DS ports on low order bits of out_portmap
        meta.portmap_metadata.out_portmap = (bit <NUM_SW_PORTS>)hdr.orca_label.src_label.spine_ds | meta.portmap_metadata.out_portmap;
        //bit_or(meta.out_portmap, meta.out_portmap, hdr.src_label.leaf_ds); //P4_14
        //output_port_select(meta.portmap_metadata.out_portmap); Extern function call
    }

    action forward_upstream() {
        // DS ports are 0, US ports on high order bits of out_portmap 
        meta.portmap_metadata.out_portmap = (bit <NUM_SW_PORTS>) hdr.orca_label.src_label.spine_us << NUM_LEAF_DS;
        //shift_left(meta.out_portmap, hdr.src_label.leaf_us, NUM_LEAF_DS); // P4_14
        //output_port_select(meta.portmap_metadata.out_portmap); Extern function call
    }

    action set_state(bit<NUM_SPINE_DS> state) { // If no state entry available forward on all of the downstream links in label
        session_state = state;
        //output_port_select(meta.portmap_metadata.out_portmap); Extern function call
    }
    
    table check_state {
        actions = {
            set_state;
            NoAction;
        }
        key = {
            hdr.ethernet.dstAddr: exact; // Session ID
        }
        size = 48;
        default_action = NoAction;
    }
    apply {
        bit<1> flag;
        session_state = 0;
        compute_filter.read(flag, 0);
        if (flag == 1) {
            new_bloom_filter = 0;
            // Example for one linkID at index 5
            // Assuming filter with K=2
            bit<8> bitstring_idx1;
            bit<8> bitstring_idx2;
            // <bit<1>(NUM_SPINE_DS) new_bloom_filter;
            bit<LINK_ID_BITS> link_id_value;
            link_ids.read(link_id_value, 5);
            //extern void hash<O, T, D, M>(out O result,
            //    in HashAlgorithm algo, in T base, in D data, in M max);
            hash(bitstring_idx1, HashAlgorithm.crc16, (bit<32>)0, {link_id_value}, (bit<32>)256);
            hash(bitstring_idx2, HashAlgorithm.crc32, (bit<32>)0, {link_id_value}, (bit<32>)256);
            new_bloom_filter = new_bloom_filter | ((bit<32>)1 << bitstring_idx1);
            new_bloom_filter = new_bloom_filter | ((bit<32>)1 << bitstring_idx2);
            link_bitstrings.write(5, new_bloom_filter);
        } 
        if (hdr.orca_label.src_label.isValid()) {
            // Assuming switch port connections: 
            // Ports [0, NUM_DS): connected to ToRs
            // Ports [NUM_DS, NUM_DS+NUM_US): connected to core switches 
            if (standard_metadata.ingress_port < NUM_SPINE_DS) { // pkt from ToR, frwrd upstream
                forward_upstream();
            } else {
                // Example for link at index 5
                // Should be done for all of the links(?)
                meta.link_metadata.link_idx = 5;
                if (hdr.orca_label.src_label.spine_common_ds[5:5] == 1){
                    standard_metadata.egress_spec = 5;
                    //clone to egress
                } else {
                    check_state.apply();
                    // This part should be done for every link 
                    // Assuming link at index 5
                    link_bitstrings.read(meta.link_metadata.link_bitstring, 5);
                    if ((meta.link_metadata.link_bitstring & hdr.orca_label.src_label.spine_ds)
                        == meta.link_metadata.link_bitstring) {
                        if (session_state[5:5] == 0) { // Not false positive
                            standard_metadata.egress_spec = 5;
                            //clone to egress
                        }
                    }   
                }
            }
        }
    }
}

V1Switch(ParserImpl(), verifyChecksum(), ingress(), egress(), computeChecksum(), DeparserImpl()) main;
