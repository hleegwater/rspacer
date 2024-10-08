html_to_doc_body <- function(path, verbose = T) {
  xml <- xml2::read_html(path)
  title    <- rvest::html_element(xml, xpath = "//title") |> rvest::html_text()

  # Select sections that have a h2 child
  sections <- rvest::html_elements(xml, xpath = "//body//section[h2]")

  section_content <- purrr::map(sections, rvest::html_children)
  section_heading <- purrr::map(section_content, ~ rvest::html_text(.x[1]))
  section_content <- purrr::map(section_content, ~ .x[-1]) #< remove heading
  names(section_content) <- section_heading

  if(verbose) {
    cli::cli_inform("{.field Title}: {title}")
    purrr::iwalk(section_heading, ~ cli::cli_inform("{.field - Section {.y}}: {.x}"))
  }

  fields = purrr::imap(section_content, ~ list(
    name = .y,
    content = .x
  ))

  list(
    name = title,
    fields = fields
  )
}

excel_rspace_document_name <- function(path, sections, document_name = NULL){
  if(!is.null(document_name)){
    if(!is.character(document_name)) cli::cli_abort(message = c("x" = "Document name should be a character string or NULL"))
    title <- document_name
  } else if("Title" %in% sections$name){
    title    <- dplyr::filter(sections, name == "Title") |> dplyr::pull(content)
  } else if("Name" %in% sections$name){
    title    <- dplyr::filter(sections, name == "Name") |> dplyr::pull(content)
  } else if("title" %in% sections$name){
    title    <- dplyr::filter(sections, name == "title") |> dplyr::pull(content)
  } else if("name" %in% sections$name){
    title    <- dplyr::filter(sections, name == "name") |> dplyr::pull(content)
  } else{
    title <- tools::file_path_sans_ext(path) |> basename()
  }
  return(title)
}

excel_to_doc_body <- function(path, document_name = NULL, verbose = T, file_type = NULL) {
  if(!file.exists(path)) cli::cli_abort(message = c("x" = glue::glue("File not found: {path}")))
  if(is.null(file_type)){
    file_type = tools::file_ext(path)
  }
  if(!file_type %in% c("xlsx", "csv", "tsv")) cli::cli_abort(message = c("x" = glue::glue("file_type is {file_type}. It should be xlsx, csv or tsv. Specify file_type manually or rename the input file.")))
  sections <- switch(file_type,
                     "xlsx" = readxl::read_excel(path, col_names = c("name", "content")),
                     "csv" = readr::read_csv(path, col_names = c("name", "content")),
                     "tsv" = readr::read_tsv(path, col_names = c("name", "content"))
  )
  # Set the Rspace entry title
  title <- excel_rspace_document_name(path, sections, document_name)

  if(verbose) {
    cli::cli_inform("{.field Title}: {title}")
    purrr::iwalk(section_heading, ~ cli::cli_inform("{.field - Section {.y}}: {.x}"))
  }
  # Get a list as required by Rspace
  fields <- data_frame_to_fields(sections)
  list(
    name = title,
    fields = fields
  )
}

attachment_upload <- function(doc_body, attachment, api_key){
  # Test if the attachment list has the correct format
  if(!is.list(attachment)) cli::cli_abort(message = c("x" = "attachment is not provided as a list"))
  if(!identical(sort(names(attachment)), c("field", "path"))) cli::cli_abort(message = c("x" = "attachment is either missing the field number or the path"))
  if(as.numeric(attachment$field) > length(doc_body$fields))  cli::cli_abort(message = c("x" = str_glue("attachment field number is higher than the total number of fields: {length(doc_body$fields)}")))

  # Upload the attachment and add its name and path to to doc_body
  json <- file_upload(attachment$path, api_key)
  doc_body$fields[[attachment$field]]$content <- glue::glue(doc_body$fields[[attachment$field]]$content,
                                                            "<p>Inserted <fileId={json$id}></p>")
  return(doc_body)
}

add_information_to_doc_body <- function(doc_body, template_id = NULL, folder_id = NULL, tags = NULL, attachment = NULL, api_key = get_api_key()){
  if(!is.null(template_id)){
    form_id <- parse_rspace_id(doc_to_form_id(template_id, verbose = F))
    doc_body$form = list(id = form_id)
  }

  if(!is.null(folder_id)) {
    doc_body$parentFolderId <- parse_rspace_id(folder_id)
  }

  if(!is.null(tags)) {
    doc_body$tags <- paste(tags, collapse = ",")
  }

  if(!is.null(attachment)) {
    doc_body <- attachment_upload(doc_body, attachment, api_key)
  }

  # The API wants a plain array -> remove the names
  names(doc_body$fields) <- NULL
  return(doc_body)
}

#' Upload a html document to Rspace
#'
#' This function can upload a html document (e.g., generated from quarto) to an
#' Rspace Basic Document, or to a Structured Document if the template is also provided.
#'
#' @param path html document to upload
#' @param template_id document id of the RSpace template used. Overwritten by the template of existing_document_id if that one is specified.
#' @param folder_id folder_id in which the document will be created (can be a notebook)
#' @param tags vector of tags to apply to the document
#' @param attachment attachment to attach to one of the fields, e.g., `list(field = 7, path = "file.txt")`
#' @param existing_document_id if you want to replace a document by a new one, specify the current identifier here.
#' @inheritParams api_status
#' @export
document_create_from_html <- function(path, template_id = NULL, folder_id = NULL, tags = NULL, attachment = NULL, api_key = get_api_key(), existing_document_id = NULL) {
  doc_body <- html_to_doc_body(path, verbose = F)

  if(!is.null(existing_document_id)){
    template_id <- existing_document_id
  }

  if(!is.null(template_id)) {
    template_fields <- doc_get_fields(template_id)

    if(length(doc_body$fields) != nrow(template_fields))
      cli::cli_abort("Document has different number of fields ({length(doc_body_fields)}) than template ({nrow(template_fields)})")
    doc_body$fields <- purrr::map2(doc_body$fields, template_fields$type, ~ {
      if(.y %in% c("string", "date")) {
        .x$content <- rvest::html_text(.x$content)
      } else {
        .x$content <- as.character(.x$content) |> paste(collapse = "\n")
      }
      .x
    })
  } else {
    # TODO Basic Document can have only 1 field
    doc_body$fields <- put_all_fields_in_one_field(doc_body$fields)
  }
  # Add tags, form ID and attachments to doc_body
  doc_body <- add_information_to_doc_body(doc_body, template_id, folder_id, tags, attachment, api_key)

  # Create or replace the document
  if(is.null(existing_document_id)){
    json <- document_post(doc_body)
  } else {
    json <- document_replace(doc_body, existing_document_id)
  }

  return(invisible(json))
}

#' Upload an Excel, csv or tsv document to Rspace
#'
#' This function can upload Excel/csv/tabular files to Rspace structured documents.
#' The file needs to have exactly two columns, one with the Rspace structured document fields and one with the content.
#'
#' @param path spreadsheet-like file to upload. Can be xlsx, csv or tsv
#' @param file_type an optional character string to specify the file type. Will be guessed from the file name if not specified.
#' @param document_name specify the name of the Rspace entry. If not specified,
#' it will be the value in Title, Name, title, or name if that is one of the fields in the Excel document.
#' If that does not exist, it will be the file name.
#' @param template_id document id of the RSpace template used
#' @param folder_id folder_id in which the document will be created (can be a notebook)
#' @param tags vector of tags to apply to the document
#' @param attachment attachment to attach to one of the fields, e.g., `list(field = 7, path = "file.txt")`
#' @param existing_document_id if you want to replace a document by a new one, specify the current identifier here.

#' @inheritParams api_status
#' @examples
#' excel_to_doc_body("assay_with_information.xlsx")
#' @export
document_create_from_excel <- function(path, file_type = NULL, document_name = NULL, template_id = NULL, folder_id = NULL, tags = NULL, attachment = NULL, api_key = get_api_key(), existing_document_id = NULL) {
  doc_body <- excel_to_doc_body(path, document_name = document_name, verbose = F, file_type = file_type)

  if(!is.null(existing_document_id)){
    template_id <- existing_document_id
  }
  if(!is.null(template_id)) {
    template_fields <- doc_get_fields(template_id)

    if(length(doc_body$fields) != nrow(template_fields))
      cli::cli_abort("Document has different number of fields ({length(doc_body_fields)}) than template ({nrow(template_fields)})")
  } else {
    # TODO Basic Document can have only 1 field
    doc_body$fields <- put_all_fields_in_one_field(doc_body$fields)
  }
  # Add tags, form ID and attachments to doc_body
  doc_body <- add_information_to_doc_body(doc_body, template_id = template_id, folder_id = folder_id, tags = tags, attachment = attachment)

  # Create or replace the document
  if(is.null(existing_document_id)){
    json <- document_post(doc_body)
  } else {
    json <- document_replace(doc_body, existing_document_id)
  }

  return(invisible(json))
}
