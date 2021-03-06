open Cow
open Macroperf

let title = Sys.argv.(1)
let comparison_switch = if Array.length Sys.argv < 3 then "comparison+bench" else Sys.argv.(2)
let result_switch = if Array.length Sys.argv < 4 then "flambda+bench" else Sys.argv.(3)

let short_switch_name sw =
  try String.sub sw 0 (String.index sw '@') with Not_found -> sw

let ( @* ) g f x = g (f x)

let ignored_topics = Topic.([
  Topic (Gc.Heap_words, Gc);
  Topic (Gc.Heap_chunks, Gc);
  Topic (Gc.Live_words, Gc);
  Topic (Gc.Live_blocks, Gc);
  Topic (Gc.Free_words, Gc);
  Topic (Gc.Free_blocks, Gc);
  Topic (Gc.Largest_free, Gc);
  Topic (Gc.Fragments, Gc);
  Topic (Size.Full, Size);
])

let score topic ~result ~comparison =
  let open Summary.Aggr in
  if result.mean = comparison.mean then 1. else
  match topic with
  | Topic.Topic (gc, Topic.Gc) when gc = Topic.Gc.Promoted_words ->
    (* Comparing ratios: use a difference *)
    1. +. result.mean -. comparison.mean
  | _ -> result.mean /. comparison.mean

let print_score score =
  let percent = score *. 100. -. 100. in
  Printf.sprintf "%+.*f%%"
    (max 0 (2 - truncate (log10 (abs_float percent))))
    percent

let average_score topic scores = match topic with
  | Topic.Topic (gc, Topic.Gc) when gc = Topic.Gc.Promoted_words -> (* linear *)
    List.fold_left ( +. ) 0. scores /. float (List.length scores)
  | _ -> (* geometric *)
    exp @@
    List.fold_left (fun acc s -> acc +. log s) 0. scores /.
    float (List.length scores)

let scorebar_style topic score =
  let leftpercent, rightpercent = match topic with
    | Topic.Topic (gc, Topic.Gc) when gc = Topic.Gc.Promoted_words ->
      if score < 1. then 50., 100. -. 50. *. score
      else 100. -. 50. *. score -. 1., 50.
    | _ ->
      if score < 1. then 50., 100. -. 50. *. score
      else 50. /. score, 50.
  in
  let gradient = [
    "transparent", 0.;
    "transparent", leftpercent;
    "#ff5555", leftpercent;
    "#ff5555", 50.;
    "#55ff88", 50.;
    "#55ff88", rightpercent;
    "transparent", rightpercent;
    "transparent", 100.;
  ] in
  Printf.sprintf "background:linear-gradient(to right,%s);border:1px solid %s"
    (String.concat "," (List.map (fun (c,p) -> Printf.sprintf "%s %.0f%%" c p) gradient))
    (if score <= 1. then "#33bb66" else "#bb4444")

(* adds _ separators every three digits for readability *)
let print_float f =
  match classify_float f with
  | FP_zero -> "0"
  | FP_infinite | FP_subnormal | FP_nan -> Printf.sprintf "%.3f" f
  | FP_normal ->
    let rec split f =
      if abs_float f >= 1000. then
        mod_float (abs_float f) 1000. ::
        split (f /. 1000.)
      else [f]
    in
    match split f with
    | [] -> assert false
    | [f] ->
      if truncate ((mod_float f 1.) *. 1000.) = 0
      then Printf.sprintf "%.f" f
      else Printf.sprintf "%.3f" f
    | last::r ->
      let first, middle = match List.rev r with
        | first::r -> first, r
        | _ -> assert false
      in
      String.concat "_"
        (Printf.sprintf "%d" (truncate first) ::
         List.map (Printf.sprintf "%03d" @* truncate) middle @
         [Printf.sprintf "%03.f" last])

let topic_unit = function
  | Topic.Topic (_, Topic.Time) -> " (ns)"
  | Topic.Topic (_, Topic.Size) -> " (bytes)"
  | Topic.Topic (gc, Topic.Gc) when gc = Topic.Gc.Promoted_words ->
    " (relative to minor words)"
  | _ -> ""

let get_bench_error switch bench =
  let res = Result.load_conv_exn Util.FS.(macro_dir / bench / switch ^ ".result") in
  match
    List.fold_left (fun acc -> function
        | `Ok {Execution.process_status = Unix.WEXITED 0} -> acc
        | `Ok ({Execution.process_status = _} as ex) -> Some ex
        | _ -> None)
      None res.Result.execs
  with
  | Some ex -> Execution.(ex.stdout, ex.stderr)
  | None -> raise Not_found

let collect () =
  let bench_dirs = Util.FS.(List.filter is_dir_exn (ls ~prefix:true macro_dir)) in
  (* Refresh summary files, which may be needed sometimes *)
  SSet.iter Summary.summarize_dir (SSet.of_list bench_dirs);
  let data_by_bench =
    List.fold_left (fun acc dir -> DB.of_dir ~acc dir) DB.empty bench_dirs
  in
  let data_by_topic =
    DB.fold_data
      (fun bench context_id topic -> DB2.add topic bench context_id)
      data_by_bench DB2.empty
  in
  let logkey ~switch ~bench = "log-" ^ switch ^"-"^ bench in
  let logs, avgscores, table_contents =
    TMap.fold (fun topic m (logs,avgscores,html) ->
        if List.mem topic ignored_topics then logs,avgscores,html else
        let bench_all, logs, bench_html =
          SMap.fold (fun bench m (acc,logs,html) ->
              let open Summary.Aggr in
              let comparison = try Some (SMap.find comparison_switch m) with Not_found -> None in
              let result = try Some (SMap.find result_switch m) with Not_found -> None in
              let acc, scorebar =
                match comparison, result with
                | Some ({success = true; _} as comparison),
                  Some ({success = true; _} as result) ->
                  let score = score topic ~result ~comparison in
                  (match classify_float (log score) with
                   | FP_nan | FP_infinite -> acc
                   | _ -> score :: acc),
                  <:html<<td class="scorebar" style="$str:scorebar_style topic score$">
                           $str:print_score score$
                         </td>&>>
                | _ ->
                  acc, <:html<<td>ERR</td>&>>
              in
              let td logs swname = function
                | Some ({success = true; _} as r) ->
                  let tooltip = Printf.sprintf "%d runs, stddev %s" r.runs (print_float r.stddev) in
                  logs,
                  <:html<<td title="$str:tooltip$">$str:print_float r.mean$</td>&>>
                | Some ({success = false; _}) ->
                  let k = logkey ~switch:swname ~bench in
                  (if SMap.mem k logs then logs
                   else try SMap.add k (get_bench_error swname bench) logs with _ -> logs),
                  <:html<<td class="error"><a href="$str:"#"^k$">ERR(run)</a></td>&>>
                | None ->
                  logs,
                  <:html<<td>-</td>&>>
              in
              let logs, td_result = td logs result_switch result in
              let logs, td_compar = td logs comparison_switch comparison in
              acc,
              logs,
              <:html<$html$
                     <tr><td class="bench-topic">$str:bench$</td>
                     $scorebar$
                     $td_result$
                     $td_compar$
                     </tr>&>>)
            m ([],logs,<:html<&>>)
        in
        let avgscore = average_score topic bench_all in
        logs,
        TMap.add topic avgscore avgscores,
        <:html<$html$
               <tr class="bench-topic">
                 <th>$str:Topic.to_string topic$$str:topic_unit topic$</th>
                 <td>$str:print_score avgscore$</td>
                 <td></td>
                 <td></td>
               </tr>
               $bench_html$>>)
      data_by_topic (SMap.empty, TMap.empty, <:html<&>>)
  in
  let table = <:html<
    <table>
       <thead><tr>
         <th>Benchmark</th>
         <th>Relative score</th>
         <th>$str:short_switch_name result_switch$</th>
         <th>$str:short_switch_name comparison_switch$</th>
       </tr></thead>
       <tbody>
         $table_contents$
       </tbody>
    </table>
  >> in
  let summary_table =
    let topics =
      TSet.of_list (List.map fst (TMap.bindings data_by_topic))
    in
    let topics =
      List.fold_left (fun acc t -> TSet.remove t acc) topics ignored_topics
    in
    let titles =
      TSet.fold (fun t html ->
          let rec sp s =
            try Bytes.set s (Bytes.index s '_') ' '; sp s
            with Not_found -> s
          in
          <:html<$html$
                 <th class="scorebar-small">
                   $str:sp (Topic.to_string t)$
                 </th>&>>)
        topics <:html<<th>Benchmark</th>&>>
    in
    let averages =
      TSet.fold (fun t html ->
          let score = TMap.find t avgscores in
          <:html<$html$
                 <td class="scorebar-small"
                     style="$str:scorebar_style t score$">
                   $str:print_score score$
                 </td>&>>)
        topics <:html<<th>Average</th>&>>
    in
    let contents =
      SMap.fold (fun bench ctx_map html ->
          let comparison_map =
            try (SMap.find comparison_switch ctx_map).Summary.data
            with Not_found -> TMap.empty
          in
          let result_map =
            try (SMap.find result_switch ctx_map).Summary.data
            with Not_found -> TMap.empty
          in
          let topics =
            TSet.fold (fun t html ->
                try
                  let open Summary.Aggr in
                  let comparison = TMap.find t comparison_map in
                  let result = TMap.find t result_map in
                  if not (comparison.success && result.success) then raise Not_found;
                  let score = score t ~result ~comparison in
                  <:html<$html$
                         <td class="scorebar-small" style="$str:scorebar_style t score$">
                           $str:print_score score$
                         </td>&>>
                with Not_found ->
                  let k = logkey ~switch:result_switch ~bench in
                  if SMap.mem k logs then
                    <:html<$html$<td class="error"><a href="$str:"#"^k$">fail</a></td>&>>
                  else
                    <:html<$html$<td>-</td>&>>)
              topics <:html<&>>
          in
          <:html<$html$
                 <tr>
                   <th>$str:bench$</th>
                   $topics$
                 </tr>
          >>)
        data_by_bench <:html<&>>
    in
    <:html< <table>
              <thead>
                <tr>$titles$</tr>
                <tr class="bench-topic">$averages$</tr>
              </thead>
              <tbody>$contents$</tbody>
            </table>
    >>
  in
  let html_logs =
    SMap.fold (fun id (stdout, stderr) html ->
        <:html< $html$
                <div class="logs" id="$str:id$">
                  <a class="close" href="#">Close</a>
                  <h3>Error running bench $str:id$</h3>
                  <h4>Stdout</h4><pre>$str:stdout$</pre>
                  <h4>Stderr</h4><pre>$str:stderr$</pre>
                </div>&>>)
      logs <:html<&>>
  in
  <:html< <h2>Summary table</h2>
          $summary_table$
          <h2>Full results</h2>
          $table$
          $html_logs$
  >>

let css = "
    table {
      margin: auto;
    }
    thead {
      position:-webkit-sticky;
      position:-moz-sticky;
      position:sticky;
      top:0;
    }
    .bench-topic {
      text-align: left;
    }
    th {
      text-align: left;
    }
    td {
      padding: 2px;
      text-align: right;
    }
    .scorebar {
      min-width: 300px;
    }
    .scorebar-small {
      font-size: small;
      width: 100px;
    }
    tr:nth-child(even) {
      background-color: #e5e5e5;
    }
    tr.bench-topic {
      background: #cce;
    }
    .error {
      background-color: #dd6666;
    }

    div {
      padding: 3ex;
    }
    pre {
      padding: 1ex;
      border: 1px solid grey;
      background-color: #eee;
    }
    .logs {
      display: none;
    }
    .logs:target {
      display: block;
      position: fixed;
      top: 5%;
      left: 5%;
      right: 5%;
      bottom: 5%;
      border: 1px solid black;
      background-color: white;
      overflow: scroll;
      z-index: 10;
    }
    .close {
      display: block;
      position: fixed;
      top: 7%;
      right: 7%;
    }
    a:target {
      background-color: #e0e000;
    }
"

let () =
  let table = collect () in
  let html =
    <:html<
      <html>
        <head>
          <title>Operf-macro, $str:title$</title>
          <style type="text/css">$str:css$</style>
        </head>
        <body>
          <h1>Operf-macro comparison</h1>
          <h3>$str:title$</h3>
          <p>For all the measures below, smaller is better</p>
          <p>Promoted words are measured as a ratio or minor words,
             and compared linearly with the reference</p>
          $table$
        </body>
      </html>
    >>
  in
  output_string stdout (Html.to_string html)
