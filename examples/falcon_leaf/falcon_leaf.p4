#include <core.p4>
#include <v1model.p4>

#include "header.p4"
#include "parser.p4"

#define NUM_VCLUSTERS_PER_RACK 8

// Used by spine schedulers, currently hardcoded (can be set from ctrl plane)
#define SWITCH_ID 1

typedef bit<HDR_QUEUE_LEN_SIZE> queue_len_t;
typedef bit<9> port_id_t;
typedef bit<8> worker_id_t;

typedef bit<QUEUE_LEN_FIXED_POINT_SIZE> len_fixed_point_t;

control egress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    action act_set_src_id(){
        hdr.falcon.src_id = SWITCH_ID;
    }

    table set_src_id {
        actions = {act_set_src_id;}
        default_action = act_set_src_id;
    }

    apply {  
        set_src_id.apply();
    }
}

control ingress(inout headers hdr, inout metadata meta, inout standard_metadata_t standard_metadata) {
    register<port_id_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) linked_iq_sched; // Spine that ToR has sent last IdleSignal.
    register<port_id_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) linked_sq_sched; // Spine that ToR has sent last QueueSignal.
    
    // List of idle workers up to 8 (idle workers) * 128 (clusters) 
    // Value 0x00 means Non-valid (NULL)
    register<worker_id_t>((bit<32>) 1024) idle_list; 
    register<bit<8>>((bit<32>) NUM_VCLUSTERS_PER_RACK) idle_count; // Idle count for each cluster, acts as pointer going frwrd and backwrd to point to idle worker list

    register<worker_id_t>((bit <32>) 1024) queue_len_list; // List of queue lens 8 (workers) * 128 (clusters)
    register<queue_len_t>((bit <32>) NUM_VCLUSTERS_PER_RACK) aggregate_queue_len_list;


    register<queue_len_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) spine_iq_len_1;
    register<queue_len_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) spine_iq_len_2;

    register<worker_id_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) spine_sw_id_1;
    register<worker_id_t>((bit<32>) NUM_VCLUSTERS_PER_RACK) spine_sw_id_2;

    //register<bit<16>>((bit <32>) 1024) workers_per_cluster;
    //register<bit<16>>((bit <32>) 1024) spines_per_cluster;

    action _drop() {
        mark_to_drop(standard_metadata);
    }
    
    action act_gen_rand_probe_group() {
        /* 
        TODO: Use modify_field_rng_uniform instead of random<> for hardware targets
        This is not implemented in bmv but available in Hardware. 
        */
        //modify_field_rng_uniform(meta.falcon_meta.rand_probe_group, 0, RAND_MCAST_RANGE);
        
        random<bit<HDR_FALCON_RAND_GROUP_SIZE>>(meta.falcon_meta.rand_probe_group, 0, RAND_MCAST_RANGE);
    }

    action act_set_queue_len_unit(len_fixed_point_t cluster_unit){
        meta.falcon_meta.queue_len_unit = cluster_unit;
    }

    action mac_forward(port_id_t port) {
        standard_metadata.egress_spec = port;
    }

    action act_gen_random_worker_id_1() {
        //modify_field_rng_uniform(meta.falcon_meta.random_downstream_id_1, 0, meta.falcon_meta.cluster_num_valid_ds);
        random<bit<HDR_SRC_ID_SIZE>>(meta.falcon_meta.random_downstream_id_1, 0, meta.falcon_meta.cluster_num_valid_ds);
    }

    action act_gen_random_worker_id_2() {
        //modify_field_rng_uniform(meta.falcon_meta.random_downstream_id_2, 0, meta.falcon_meta.cluster_num_valid_ds);
        random<bit<HDR_SRC_ID_SIZE>>(meta.falcon_meta.random_downstream_id_2, 0, meta.falcon_meta.cluster_num_valid_ds);
    }

    action act_get_cluster_num_valid_ds(bit<8> num_ds_elements) {
        meta.falcon_meta.cluster_num_valid_ds = num_ds_elements;
    }

    action act_read_idle_count() {
        idle_count.read(meta.falcon_meta.cluster_idle_count, (bit<32>) hdr.falcon.local_cluster_id);
        /* TODO: use "add_to_field" for hardware targets, simply "+" in bvm */
        meta.falcon_meta.cluster_idle_count = meta.falcon_meta.cluster_idle_count + 1;
        meta.falcon_meta.idle_worker_index = (bit <16>) meta.falcon_meta.cluster_idle_count + (bit <16>) hdr.falcon.local_cluster_id * MAX_WORKERS_PER_CLUSTER;
        
        //add_to_field(meta.falcon_meta.cluster_idle_count, 1);
        //add_to_field(meta.falcon_meta.idle_worker_index, meta.falcon_meta.cluster_idle_count);
        //add_to_field(meta.falcon_meta.idle_worker_index, hdr.falcon.local_cluster_id);
    }

    action act_add_to_idle_list() {
        idle_list.write((bit<32>) meta.falcon_meta.idle_worker_index, hdr.falcon.src_id);
    }

    action act_pop_from_idle_list () {
        idle_list.read(meta.falcon_meta.idle_downstream_id, (bit<32>) meta.falcon_meta.idle_worker_index);
        meta.falcon_meta.idle_worker_index = meta.falcon_meta.idle_worker_index - 1;
        //add_to_field(meta.falcon_meta.idle_worker_index, -1);
    }

    action act_decrement_queue_len() {
        // Update queue len
        meta.falcon_meta.worker_index = (bit<16>) hdr.falcon.src_id + ((bit<16>) hdr.falcon.local_cluster_id * MAX_WORKERS_PER_CLUSTER);
        queue_len_list.read(meta.falcon_meta.qlen_curr, (bit<32>)meta.falcon_meta.worker_index);
        meta.falcon_meta.qlen_curr = meta.falcon_meta.qlen_curr - meta.falcon_meta.queue_len_unit;
        queue_len_list.write((bit<32>)meta.falcon_meta.worker_index, meta.falcon_meta.qlen_curr);

        aggregate_queue_len_list.read(meta.falcon_meta.qlen_agg, (bit<32>) hdr.falcon.local_cluster_id);
        meta.falcon_meta.qlen_agg = meta.falcon_meta.qlen_agg - 1;
        aggregate_queue_len_list.write((bit<32>) hdr.falcon.local_cluster_id, meta.falcon_meta.qlen_agg);
    }

    action act_forward_falcon(bit<9> port) {
        standard_metadata.egress_spec = port;
    }

    action act_cmp_random_qlen() {
        if (meta.falcon_meta.random_downstream_id_1 == meta.falcon_meta.random_downstream_id_2){
            meta.falcon_meta.selected_downstream_id = meta.falcon_meta.random_downstream_id_1;
        }
        queue_len_list.read(meta.falcon_meta.qlen_rand_1, (bit<32>) meta.falcon_meta.random_downstream_id_1);
        queue_len_list.read(meta.falcon_meta.qlen_rand_2, (bit<32>) meta.falcon_meta.random_downstream_id_2);
        if (meta.falcon_meta.qlen_rand_1 >= meta.falcon_meta.qlen_rand_2) {
            meta.falcon_meta.selected_downstream_id = meta.falcon_meta.qlen_rand_2;
        } else {
            meta.falcon_meta.selected_downstream_id = meta.falcon_meta.qlen_rand_1;
        }
    }

    action act_increment_queue_len() {
        queue_len_list.read(meta.falcon_meta.qlen_curr, (bit<32>)meta.falcon_meta.selected_downstream_id);
        meta.falcon_meta.qlen_curr = meta.falcon_meta.qlen_curr + 1;
        queue_len_list.write((bit<32>)meta.falcon_meta.selected_downstream_id, meta.falcon_meta.qlen_curr);        
    }

    table set_queue_len_unit {
        key = {
            hdr.falcon.cluster_id: exact;
        }
        actions = {
            act_set_queue_len_unit;
            _drop;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = _drop;
    }

    table gen_random_probe_group {
        actions = {act_gen_rand_probe_group;}
        default_action = act_gen_rand_probe_group;
    }

    table gen_random_downstream_id_1 {
        actions = {act_gen_random_worker_id_1;}
        default_action = act_gen_random_worker_id_1;
    }

    table gen_random_downstream_id_2 {
        actions = {act_gen_random_worker_id_2;}
        default_action = act_gen_random_worker_id_2;
    }

    // Gets the actual number of downstream elements (workers or tor schedulers) for vcluster (passed by ctrl plane)
    table get_cluster_num_valid_ds {
        key = {
            hdr.falcon.cluster_id : exact;
        }
        actions = {
            act_get_cluster_num_valid_ds;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }

    table read_idle_count {
        actions = {act_read_idle_count;}
        default_action = act_read_idle_count;
    }

    table add_to_idle_list {
        actions = {act_add_to_idle_list;}
        default_action = act_add_to_idle_list;
    }

    table pop_from_idle_list {
        actions = {act_pop_from_idle_list;}
        default_action = act_pop_from_idle_list;
    }

    // table get_worker_index {
    //     actions = {act_get_worker_index;}
    //     default_action = act_get_worker_index;
    // }

    table decrement_queue_len {
        actions = {act_decrement_queue_len;}
        default_action = act_decrement_queue_len;
    }

    table cmp_random_qlen {
        actions = {act_cmp_random_qlen;}
        default_action = act_cmp_random_qlen;
    }
    // Currently uses the ID of workers to forward downstream.
    // Mapping from worker IDs for each vcluster to physical port passed by control plane tables. 
    table forward_falcon {
        key = {
            meta.falcon_meta.selected_downstream_id: exact;
            hdr.falcon.cluster_id: exact;
        }
        actions = {
            act_forward_falcon;
            NoAction;
        }
        size = HDR_SRC_ID_SIZE;
        default_action = NoAction;
    }

    table increment_queue_len {
        actions = {act_increment_queue_len;}
        default_action = act_increment_queue_len;
    }

    
    apply {
        if (hdr.falcon.isValid()) {
            read_idle_count.apply();
            if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                set_queue_len_unit.apply();
                decrement_queue_len.apply();
                port_id_t target_port; 
                linked_sq_sched.read(target_port, (bit<32>) hdr.falcon.local_cluster_id);
                if (target_port != 0) { // not Null. TODO fix Null value 0 port is valid
                    hdr.falcon.pkt_type = PKT_TYPE_QUEUE_SIGNAL;
                    hdr.falcon.qlen = meta.falcon_meta.qlen_agg; // Reporting agg qlen to Spine
                    standard_metadata.egress_spec = target_port;
                }
                if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                    if (meta.falcon_meta.cluster_idle_count < MAX_IDLE_WORKERS_PER_CLUSTER) {
                        add_to_idle_list.apply();
                    }
                    if (meta.falcon_meta.cluster_idle_count == 1) { // Just became Idle, need to anounce to a spine scheduler
                        gen_random_probe_group.apply();
                        hdr.falcon.pkt_type = PKT_TYPE_PROBE_IDLE_QUEUE; // Send probes
                        /* TODO: use "modify_field()" for hardware targets */ 
                        standard_metadata.mcast_grp = (bit <16>) meta.falcon_meta.rand_probe_group;
                        //modify_field(standard_metadata.mcast_grp, meta.falcon_meta.rand_probe_group);
                    }
                }
            } else if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                if (meta.falcon_meta.cluster_idle_count > 0) { //Idle workers available
                    pop_from_idle_list.apply();
                    if (meta.falcon_meta.cluster_idle_count == 1) { // No more idle after this assignment
                        linked_iq_sched.write(0, 0); // Set to NULL
                    }
                } else {
                    get_cluster_num_valid_ds.apply();
                    gen_random_downstream_id_1.apply();
                    gen_random_downstream_id_2.apply();
                    cmp_random_qlen.apply();
                }
                increment_queue_len.apply();
                forward_falcon.apply();
            } 
            
        } else {
            // Apply regular switch procedure
        }
    }
}

V1Switch(ParserImpl(), verifyChecksum(), ingress(), egress(), computeChecksum(), DeparserImpl()) main;
