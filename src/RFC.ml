(* Copyright (C) 2021, Francois Berenger

   Tsuda laboratory, Tokyo university,
   5-1-5 Kashiwa-no-ha, Kashiwa-shi, Chiba-ken, 277-8561, Japan. *)

(* Random Forets Classifier *)

module A = BatArray
module Ht = Hashtbl
module IntMap = BatMap.Int
module IntSet = BatSet.Int
module L = BatList
module Log = Dolog.Log
module RNG = BatRandom.State

open Printf

type features = int IntMap.t
type internal_features = (int, int) Ht.t
type class_label = int

type sample = features (* X *) *
              class_label (* y *)

type internal_sample = internal_features (* X *) *
              class_label (* y *)

type tree = Leaf of class_label
          | Node of tree (* lhs *) *
                    int * int (* (feature, threshold) *) *
                    tree (* rhs *)

type metric = Gini (* default *)
            | Shannon (* TODO; WARN: check min value is still 0.0 *)
            | MCC (* TODO; WARN: check min value is still 0.0 *)

let to_internal_features feat =
  Ht.of_seq (IntMap.to_seq feat)

let to_features feat =
  IntMap.of_seq (Ht.to_seq feat)

let to_internal_sample (feat, class_label) =
  (to_internal_features feat, class_label)

let to_sample (internal_feat, class_label) =
  (to_features internal_feat, class_label)

(* a feature with non constant value allows to discriminate samples *)
let collect_non_constant_features_internal (samples : (internal_features * 'a) array) =
  let feat_vals = Ht.create 11 in
  A.iter (fun (features, _class_label) ->
      Ht.iter (fun feature value ->
          try
            let prev_values = Ht.find feat_vals feature in
            Ht.replace feat_vals feature (IntSet.add value prev_values)
          with Not_found ->
            Ht.add feat_vals feature
              (* we have a sparse representation:
                 always explicitely add the 0 value then *)
              IntSet.(add value (singleton 0))
        ) features
    ) samples;
  Ht.fold (fun feat vals acc ->
      if Utls.is_singleton vals then acc
      else (feat, vals) :: acc
    ) feat_vals []

let collect_non_constant_features (samples : (features * 'a) array) =
  collect_non_constant_features_internal (Array.map to_internal_sample samples)

let feat_get feat features =
  try Ht.find features feat with
  | Not_found -> 0

(* split a node *)
(* FBR: maybe this can be accelerated:
 *   we need all samples sorted per feature;
 *   we need a list of the index of remaining samples *)
let partition_samples_internal feature threshold (samples : (internal_features * 'a) array) =
  A.partition (fun (features, _class_label) ->
      (* sparse representation --> 0s almost everywhere *)
      let value = feat_get feature features in
      value <= threshold
    ) samples

let partition_samples feature threshold (samples : (features * 'a) array) =
  let left, right =
    partition_samples_internal feature threshold (Array.map to_internal_sample samples)
  in
  (Array.map to_sample left, Array.map to_sample right)

let _partition_samples_index index feature threshold sample_indexes =
  (* sample indexes with feat's val <= threshold *)
  let le_set = IntMap.find threshold (IntMap.find feature index) in
  A.partition (fun i ->
      IntSet.mem i le_set
    ) sample_indexes

(* for each (feat, threshold) pair, record the set of samples
   (just their indexes in fact) which have feat_val <= threshold *)
let _index_samples samples =
  let all_sample_indexes = (* [0..n-1] *)
    let n = A.length samples in
    IntSet.of_array (A.init n (fun i -> i)) in
  let feat_vals = collect_non_constant_features_internal samples in
  L.fold_left (fun acc1 (feature, values) ->
      IntMap.add feature
        (fst
           (IntSet.fold (fun threshold (acc2, rem_samples) ->
                let left, right =
                  IntSet.partition (fun i ->
                      let features = fst samples.(i) in
                      let value = feat_get feature features in
                      value <= threshold
                    ) rem_samples in
                (* Log.info "feat: %d val: %d left: %d right: %d"
                 *   feature threshold
                 *   (IntSet.cardinal left) (IntSet.cardinal right); *)
                (IntMap.add threshold left acc2, right)
              ) values (IntMap.empty, all_sample_indexes)
           )
        ) acc1
    ) IntMap.empty feat_vals

(* how many times we see each class label *)
let class_count_samples (samples : internal_sample array) =
  let counts = A.create 2 0 in
  A.iter (fun (_features, class_label) ->
      counts.(class_label) <- counts.(class_label) + 1 ;
    ) samples;
  counts

let class_count_labels labels =
  let ht = Ht.create 11 in
  A.iter (fun class_label ->
      let prev_count =
        try Ht.find ht class_label with
        | Not_found -> 0
      in
      Ht.replace ht class_label (prev_count + 1)
    ) labels;
  ht

(* Formula comes from the book:
   "Hands-on machine learning with sklearn ...", A. Geron.
   Same formula in wikipedia. *)
let gini_impurity (samples : internal_sample array) =
  let n = float (A.length samples) in
  let counts = class_count_samples samples in
  let sum_pi_squares =
    A.fold (fun acc count ->
        let p_i = (float count) /. n in
        (p_i *. p_i) +. acc
      ) 0.0 counts in
  1.0 -. sum_pi_squares

let metric_of = function
  | Gini -> gini_impurity
  | MCC -> failwith "not implemented yet"
  | Shannon -> failwith "not implemented yet"

(* Formula comes from the book:
   "Hands-on machine learning with sklearn ...", A. Geron.
   It must be minimized. *)
let cost_function metric left right =
  let card_left = A.length left in
  let card_right = A.length right in
  let n = float (card_left + card_right) in
  match card_left, card_right with
  | 0, 0 -> assert(false)
  | 0, _ -> metric right (* NaN protect *)
  | _, 0 -> metric left (* NaN protect *)
  | _, _ ->
    let w_left = (float card_left) /. n in
    let w_right = (float card_right) /. n in
    ((w_left  *. (metric left)) +.
     (w_right *. (metric right)))

let majority_class rng (samples : internal_sample array) =
  if A.length samples = 0 then
    assert(false)
  else if A.length samples = 1 then
    snd (samples.(0)) (* single label *)
  else
    let ht = class_count_samples samples in
    (* find max count *)
    let max_count = A.fold Int.max 0 ht in
    (* randomly draw from all those with max_count *)
    let majority_classes = A.fold_lefti (fun acc class_label count ->
          if count = max_count then class_label :: acc
          else acc
        ) [] ht in
    (* let chosen = Utls.array_rand_elt rng majority_classes in
     * Log.info "majority: %d" chosen;
     * chosen *)
    Utls.list_rand_elt rng majority_classes

let fst5 (a, _, _, (_, _)) = a

let choose_min_cost rng = function
  | [] -> assert(false)
  | [x] -> x
  | cost_splits ->
    let min_cost = L.min (L.rev_map fst5 cost_splits) in
    (* Log.info "min_cost: %f" min_cost; *)
    let candidates =
      L.fold (fun acc (cost, feature, value, (left, right)) ->
          if cost = min_cost then
            (cost, feature, value, (left, right)) :: acc
          else acc
        ) [] cost_splits in
    Utls.list_rand_elt rng candidates

(* [dichotomic_search elts pred] assumes that [pred] is
   a monotonic predicate wrt [elts]: if [pred elts.(i)]
   is verified then [pred elts.(j)] must hold for all [0 <= j <= i].

   This function returns [All_above] if no element
   satisfies [pred]. Otherwise, it returns [Below_index k] with
   [k] the greatest index such that no element [elts.(i)] with
   [i > k] verifies [pred].

   Example:

   val array : int array = [|10; 20; 20; 30|]

   # dichotomic_search array (fun elt -> elt <= 9) ;;
   - : result = All_above

   # dichotomic_search array (fun elt -> elt <= 10) ;;
   - : result = Below_index 0

   # dichotomic_search array (fun elt -> elt <= 19) ;;
   - : result = Below_index 0

   # dichotomic_search array (fun elt -> elt <= 20) ;;
   - : result = Below_index 2

   # dichotomic_search array (fun elt -> elt <= 29) ;;
   - : result = Below_index 2

   # dichotomic_search array (fun elt -> elt <= 30) ;;
   - : result = Below_index 3

   # dichotomic_search array (fun elt -> elt <= 31) ;;
   - : result = Below_index 3
 *)
(* let dichotomic_search (elts : 'a array) pred =
 *   let rec loop low hi =
 *     if low = hi then
 *       let x = elts.(low) in
 *       if pred x then
 *         Below_index low
 *       else
 *         Below_index (low - 1)
 *     else
 *       (let mid = low + (hi - low) / 2 in
 *        let x = elts.(mid) in
 *        if pred x then
 *          loop (mid + 1) hi
 *        else
 *          loop low mid)
 *    in
 *    let last = Array.length elts - 1 in
 *    if pred elts.(0) then
 *      loop 0 last
 *    else
 *      All_above *)

let fold_partitions f list acc =
  let rec loop f list prefix acc =
    match list with
    | [] -> assert false
    | [x, bucket] ->
      let suffix = bucket in
      let acc = f x prefix suffix acc in
      acc, suffix
    | (x, bucket) :: tl ->
      let acc, suffix = loop f tl (List.rev_append bucket prefix) acc in
      let suffix = List.rev_append bucket suffix in
      let acc = f x prefix suffix acc in
      acc, suffix
  in
  let acc, _ =
    loop f list [] acc in acc

(* maybe this is called the "Classification And Regression Tree" (CART)
   algorithm in the litterature *)
let tree_grow (rng: Random.State.t) (* seeded RNG *)
    (metric: internal_sample array -> float) (* hyper params *)
    (max_features: int)
    (max_samples: int)
    (min_node_size: int)
    (training_set: internal_sample array) (* dataset *) : tree * int array =
  let bootstrap, oob =
    (* First randomization introduced by random forests: bootstrap sampling *)
    Utls.array_bootstrap_sample_OOB rng max_samples training_set in
  let rec loop (samples : internal_sample array) =
    (* min_node_size is a regularization parameter; it also allows to
     * abort tree building (might be interesting for very large datasets) *)
    if A.length samples <= min_node_size then
      Leaf (majority_class rng samples)
    else
      (* collect all non constant features *)
      let split_candidates =
        let all_candidates = collect_non_constant_features_internal samples in
        (* randomly keep only N of them:
           Second randomization introduced by random forests
           (random feature sampling). *)
        L.take max_features (L.shuffle ~state:rng all_candidates) in
      match split_candidates with
      | [] -> (* cannot discriminate samples further *)
        Leaf (majority_class rng samples)
      | _ ->
        (* select the (feature, threshold) pair minimizing cost *)
        let table = Hashtbl.create 11 in
        let split_costs =
          L.fold (fun acc (feature, values) ->
              Hashtbl.clear table ;
              A.iter (fun ((f, _cl) as sample) ->
                  Hashtbl.add table (feat_get feature f) sample
                ) samples ;
              let buckets : (int * internal_sample list) list =
                IntSet.to_seq values
                |> Seq.map (fun value ->
                    let samples = Hashtbl.find_all table value in
                    (value, samples))
                |> List.of_seq
              in
              fold_partitions (fun value left right acc ->
                let left = Array.of_list left in
                let right = Array.of_list right in
                let cost = cost_function metric left right in
                (cost, feature, value, (left, right)) :: acc
              ) buckets acc
          ) [] split_candidates in
        (* choose one split minimizing cost *)
        let cost, feature, threshold, (left, right) =
          choose_min_cost rng split_costs in
        if A.length left = 0 then
          Leaf (majority_class rng right)
        else if A.length right = 0 then
          Leaf (majority_class rng left)
        else if cost = 0.0 then
          (* if the cost is minimal: pure nodes -> stop digging *)
          Node (Leaf (majority_class rng left), feature, threshold,
                Leaf (majority_class rng right))
        else
          Node (loop left, feature, threshold, loop right)
  in
  (loop (* 0 *) bootstrap, oob)

(* array of all samples whose index is listed *)
let extract indexes (samples: sample array): sample array =
  A.map (A.unsafe_get samples) indexes

let rand_max_bound = 1073741823 (* 2^30 - 1 *)

(* FBR: this should go into parany *)
(* array input order is preserved (REQUIRED by predict_many) *)
let array_parmap ncores f a init =
  let n = A.length a in
  let res = A.create n init in
  Parany.run ncores
    ~demux:(
      let in_count = ref 0 in
      fun () ->
        if !in_count = n then
          raise Parany.End_of_input
        else
          let i = !in_count in
          incr in_count;
          i)
    ~work:(fun i -> (i, f (A.unsafe_get a i)))
    ~mux:(fun (i, y) -> A.unsafe_set res i y);
  res


let forest_grow
    ncores rng metric ntrees max_features max_samples min_node_size train =
  (* treat the RNG as a seed stream, for reproducibility
     despite potentially out of order parallel run *)
  let seeds = A.init ntrees (fun _ -> RNG.int rng rand_max_bound) in
  array_parmap ncores
    (fun seed ->
       let rng' = RNG.make [|seed|] in
       let now = Unix.gettimeofday () in
       let res = tree_grow rng' metric max_features max_samples min_node_size train in
       let later = Unix.gettimeofday () in
       Format.printf "processing time: %f@." (later -. now) ;
       res
    )
    seeds (Leaf 0, [||])

type int_or_float = Int of int (* exact count *)
                  | Float of float (* proportion *)

type forest = (tree * int array) array

(* before saving a model, we might want to just get rid of the OOB
 * sample indexes *)
let drop_OOB (f: forest): forest =
  A.map (fun (t, _oob) -> (t, [||])) f

let ratio_to_int mini maxi var_name x =
  Utls.bound_between mini maxi (match x with
      | Int i -> i
      | Float f ->
        let () =
          Utls.enforce (0.0 < f && f <= 1.0)
            (sprintf "RFC.ratio_to_int: %s not in ]0.0,1.0]" var_name) in
        BatFloat.round_to_int (f *. (float maxi))
    )

let train (ncores: int)
    (rng: Random.State.t)
    (metric: metric)
    (ntrees: int)
    (max_features: int_or_float)
    (card_features: int)
    (max_samples: int_or_float)
    (min_node_size: int)
    (train: sample array): forest =
  Utls.enforce (1 <= ntrees) "RFC.train: ntrees < 1";
  let metric_f = metric_of metric in
  let max_feats = ratio_to_int 1 card_features "max_features" max_features in
  let n = A.length train in
  let max_samps = ratio_to_int 1 n "max_samples" max_samples in
  let min_node =
    let () =
      Utls.enforce (1 <= min_node_size && min_node_size < n)
        "RFC.train: min_node_size not in [1,n[" in
    min_node_size in
  let train = Array.map to_internal_sample train in
  forest_grow
    ncores rng metric_f ntrees max_feats max_samps min_node train

(* predict for one sample using one tree *)
let tree_predict tree (features, _label) =
  let rec loop = function
    | Leaf label -> label
    | Node (lhs, feature, threshold, rhs) ->
      let value = feat_get feature features in
      if value <= threshold then
        loop lhs
      else
        loop rhs in
  loop tree

(* label to predicted probability hash table *)
let predict_one_proba ncores forest x =
  let x = to_internal_sample x in
  let pred_labels =
    array_parmap ncores
      (fun (tree, _oob) -> tree_predict tree x) forest 0 in
  let label_counts = class_count_labels pred_labels in
  let ntrees = float (A.length forest) in
  Ht.fold (fun label count acc ->
      (label, (float count) /. ntrees) :: acc
    ) label_counts []

let predict_one ncores rng forest x =
  let label_probabilities = predict_one_proba ncores forest x in
  let p_max = L.max (L.rev_map snd label_probabilities) in
  let candidates =
    L.filter (fun (_label, p) -> p = p_max) label_probabilities in
  Utls.list_rand_elt rng candidates

let predict_one_margin ncores rng forest x =
  let label_probabilities = predict_one_proba ncores forest x in
  let p_max = L.max (L.rev_map snd label_probabilities) in
  let candidates =
    L.filter (fun (_label, p) -> p = p_max) label_probabilities in
  let pred_label, pred_proba = Utls.list_rand_elt rng candidates in
  let other_label_p_max =
    L.fold_left (fun acc (label, p) ->
        if label <> pred_label then
          max acc p
        else
          acc
      ) 0.0 candidates in
  let margin = pred_proba -. other_label_p_max in
  (pred_label, pred_proba, margin)

(* FBR: check when we really need to create a new RNG *)

(* will scale better than predict_one *)
let predict_many ncores rng forest xs =
  array_parmap ncores (predict_one 1 rng forest) xs (0, 0.0)

let predict_many_margin ncores rng forest xs =
  array_parmap ncores (predict_one_margin 1 rng forest) xs (0, 0.0, 0.0)

let predict_OOB rng forest train =
  let n = A.length train in
  let oob_idx2preds = Ht.create n in
  A.iter (fun (tree, oob) ->
      let train_OOB = Array.map to_internal_sample @@ extract oob train in
      let truths = A.map snd train_OOB in
      let preds = A.map (tree_predict tree) train_OOB in
      Utls.array_iter3 oob truths preds (fun oob_idx truth pred ->
          try
            let prev_truth, prev_preds = Ht.find oob_idx2preds oob_idx in
            assert(prev_truth = truth);
            Ht.replace oob_idx2preds oob_idx (prev_truth, pred :: prev_preds)
          with Not_found ->
            Ht.add oob_idx2preds oob_idx (truth, [pred])
        )
    ) forest;
  let truth_preds = A.create (Ht.length oob_idx2preds) (0, 0) in
  Utls.ht_iteri (fun i _oob_idx (truth, preds') ->
      let preds =
        let pred_labels = A.of_list preds' in
        A.map (fun label -> (IntMap.empty, label)) pred_labels in
      let preds = Array.map to_internal_sample preds in
      A.unsafe_set truth_preds i (truth, majority_class rng preds)
    ) oob_idx2preds;
  truth_preds

(* MCC for particular class of interest *)
let mcc target_class truth_preds =
  let tp_ = ref 0 in
  let tn_ = ref 0 in
  let fp_ = ref 0 in
  let fn_ = ref 0 in
  A.iter (fun (truth, pred) ->
      match truth = target_class, pred = target_class with
      | true , true  -> incr tp_
      | false, false -> incr tn_
      | true , false -> incr fn_
      | false, true  -> incr fp_
    ) truth_preds;
  let tp = !tp_ in
  let tn = !tn_ in
  let fp = !fp_ in
  let fn = !fn_ in
  Log.info "TP: %d TN: %d FP: %d FN: %d" tp tn fp fn;
  float ((tp * tn) - (fp * fn)) /.
  sqrt (float ((tp + fp) * (tp + fn) * (tn + fp) * (tn + fn)))

let accuracy truth_preds =
  let n = A.length truth_preds in
  let correct_preds = ref 0 in
  A.iter (fun (truth, pred) ->
      if truth = pred then incr correct_preds
    ) truth_preds;
  (float !correct_preds) /. (float n)

module Score_label = struct
  type t = float * bool
  let get_score (s, _l) = s
  let get_label (_s, l) = l
end

module ROC = Cpm.MakeROC.Make(Score_label)

let roc_auc target_class preds true_labels =
  let score_labels =
    A.map2 (fun (pred_label, pred_proba) true_label ->
        if pred_label = target_class then
          (pred_proba, true_label = target_class)
        else
          (1.0 -. pred_proba, true_label = target_class)
      ) preds true_labels in
  ROC.auc_a score_labels

type filename = string

let save fn forest =
  Utls.save fn (drop_OOB forest)

let restore fn =
  Utls.restore fn
