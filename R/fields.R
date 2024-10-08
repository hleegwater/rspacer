# Functions to process Rspace structured document fields

data_frame_to_fields <- function(fields_data_frame) {
  fields <- lapply(1:nrow(fields_data_frame), function(row_nr) {
    list("name" = fields_data_frame$name[row_nr],
         "content" = fields_data_frame$content[row_nr])
  })
  names(fields) <- fields_data_frame$name
  return(fields)
}

fields_to_data_frame <- function(fields){
  tibble::tibble(fields = fields) |> tidyr::unnest_wider("fields")
}

doc_get_fields <- function(doc_id, api_key = get_api_key()) {
  doc <- document_retrieve(doc_id, api_key)
  fields_to_data_frame(doc$fields)
}

#' put_all_fields_in_one_field
#'
#' Put a list of fields into one field. This can be needed when no Structured
#' Document template is specified and a Basic Document is used, but the
#' html/excel/other input has multiple subheaders or fields.
#' @param doc_body_fields multiple fields in a list
#' @param use_html_sep If `TRUE`, each field is placed in a html paragraph, with </p> and <p>
#' @returns a list with one field, with only content, all contents from other fields, separated by `\n`.
#' @examples
#' doc_body$fields <- put_all_fields_in_one_field(doc_body$fields)
#'
put_all_fields_in_one_field <- function(doc_body_fields, use_html_sep = T){
  text_content <- fields_to_data_frame(doc_body_fields)

  if(use_html_sep){
    text_content <- text_content |>
      dplyr::mutate(content = paste0("<p>", as.character(content), "</p>"))
  }
  # Collapse content into one field
  text_content <- text_content |>
    dplyr::pull(content) |> paste(collapse = "\n")

  return(list(list("content" = text_content)))
}
