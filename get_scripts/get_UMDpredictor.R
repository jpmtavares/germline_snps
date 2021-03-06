#!/usr/bin/Rscript

##########################################################
#                                                        #
#                     UMD-predictor                      #
#                                                        #
##########################################################
system(
"body() {
    IFS= read -r header
    printf '%s\n' '$header'
    '$@'
}"
)

#______________________________________________
# libraries
#______________________________________________
library(readr, quietly = T)
library(stringr, quietly = T)
library(biomaRt, quietly = T)
library(dplyr, quietly = T, warn.conflicts = F)
library(parallel, quietly = T)
#__________________________________________________________
# SET GENOMEDARCHIVE and other PATHS
#__________________________________________________________
GENOMEDARCHIVE<-"/media/joanatavares/716533eb-f660-4a61-a679-ef610f66feed/"
if(!dir.exists(GENOMEDARCHIVE)){
  GENOMEDARCHIVE<-"/genomedarchive/"
}
CRICK<-paste(GENOMEDARCHIVE, "Crick_storage/", sep="")
LOVELACE<-paste(GENOMEDARCHIVE, "Lovelace_decoding/", sep="")
MENDEL<-paste(GENOMEDARCHIVE, "Mendel_annotating/", sep="")

setwd(MENDEL)
#______________________________________________
# HELP function
#______________________________________________
# collect arguments
args <- commandArgs(TRUE)

# parse arguments (in the form --arg=value)
parseArgs <- function(x) strsplit(sub("^--", "", x), "==")
argsL <- as.list(as.character(as.data.frame(do.call("rbind", parseArgs(args)))$V2))

if(length(argsL)==0 & !is.null(argsL)){
  argsL <- as.list("--help")
}

names(argsL) <- as.data.frame(do.call("rbind", parseArgs(args)))$V1
args <- argsL
rm(argsL)

# Default setting when no all arguments passed or help needed
if("--help" %in% args | is.null(args$RefSeq)) {
  cat("
      get_UMDpredictor.R [--help] [--RefSeq==<RefSeq GRCh37 annotation file>] [--column==<number of column with ENSTranscripts>]

      -- program to get umd-predictor.eu prediction scores for a list of Ensembl Transcripts IDs --
      
      where:
      --RefSeq                             RefSeq GRCh37 annotation file
      --column                             [default: script will look for a column named ENSTranscript] number of column with ENSTranscripts\n\n")
  
  q(save="no")
}

#__________________________________________________________
# FUNCTIONS
#__________________________________________________________
revcomp<-function(DNAnucleotides){
  chartr("ATGC", "TACG", DNAnucleotides)
}

UMDpredictor<-function(ENSTranscripts){
  # create url for each transcript
  url<-paste("http://umd-predictor.eu/transcript_query2.php?name=",
             str_extract(ENSTranscripts,"(?<=0{5}).*$"),sep="")
  # read trnascript information
  umd<-mclapply(url, function(x) {
    tryCatch({
      print(paste("Get ENST00000", str_extract(x,"\\d{6}"), " transcript.", sep=""))
      read.delim(x, header = F)},
      error=function(e){NULL})
  }, mc.preschedule = TRUE, mc.cores = 8)
  
  # remove error entries
  print(paste("Couldn't get results for", ENSTranscripts[sapply(umd, is.null)], "transcript.", sep=" "))
  ENSTranscripts<-ENSTranscripts[!sapply(umd, is.null)]
  umd<-umd[!sapply(umd, is.null)]
  
  # add ENSTranscript column
  umd<-mcmapply(cbind, "ENSTranscript"=ENSTranscripts, umd,  SIMPLIFY=F, mc.preschedule = TRUE, mc.cores = 8)
  umd<-mclapply(umd, setNames, c("ENSTranscript","TranscriptPosition","Position","HGVS_c","HGVSp",
                                 "score","UMD-predictor"), mc.preschedule = TRUE, mc.cores = 8)
  #________________________________
  # Get info from Ensembl biomart
  #________________________________
  print("Getting Ensembl transcript information from BioMart...")
  ensembl<-useMart("ensembl", dataset="hsapiens_gene_ensembl")
  Ensembl_info<-getBM(attributes = c('chromosome_name', 'hgnc_symbol','strand','ensembl_transcript_id'), 
                      filters = 'ensembl_transcript_id', 
                      values = ENSTranscripts, 
                      mart = ensembl)
  names(Ensembl_info)<-c("Chr", "HGNC_symbol", "Strand", "ENSTranscript")
  print("BioMart retrieved.")
  
  # join Ensembl and UMD-predictor
  print("Joining results...")
  result<-mclapply(umd, left_join, Ensembl_info, mc.preschedule = TRUE, mc.cores = 8)
  #________________________________
  # Get final table
  #________________________________
  # get REF and ALT alleles and combine everything into a final table
  final<-mclapply(result, function(x){
    alleles<-do.call(rbind.data.frame, str_extract_all(as.character(x$HGVS_c), "[ACGT]"))
    names(alleles)<-c("Ref","Alt")
    #________________________________
    # Reverse complement
    #________________________________
    alleles$Ref<-ifelse(as.numeric(as.character(x$Strand))==-1,
                        revcomp(alleles$Ref),
                        as.character(alleles$Ref))
    alleles$Alt<-ifelse(as.numeric(as.character(x$Strand))==-1,
                        revcomp(alleles$Alt),
                        as.character(alleles$Alt))
    #________________________________
    # Get final table
    #________________________________
    return(data.frame(Chr=x$Chr, Position=x$Position, Ref=alleles$Ref, Alt=alleles$Alt,
                      HGVS_c=x$HGVS_c, HGVS_p=x$HGVSp, HGNC_symbol=x$HGNC_symbol,
                      ENSTranscript=x$ENSTranscript, UMD_pred=x$`UMD-predictor`,
                      UMD_score=x$score))
  }, mc.preschedule = TRUE, mc.cores = 8)
  
  return(final)
}

#________________________________________________________
# start log file
#________________________________________________________
filename<-"grch37.clin.UMDpredictor"
sink(file = paste("log_", filename,".txt", sep=""), append = FALSE, type = c("output"),
     split = TRUE)
#________________________________________________________
# SETUP
#________________________________________________________
transcripts<-read.delim(args[["RefSeq"]], header=T)

if(is.null(args$column)){
  tryCatch({
    transcripts<-transcripts["ENSTranscript"]
    print("ENSTranscript column was found in input file.")
  },
  error=function(e){print("There's no column named ENSTranscript. Please choose --column parameter.")})
} else{
  if(any(grep("ENST", transcripts[,as.numeric(as.character(args$column))]))){
    transcripts<-transcripts[,as.numeric(as.character(args$column))]
  } else{
    stop(paste("Column number", as.numeric(as.character(args$column)), "is not ENSTranscript column. Please choose another column number.", sep=" "))
  }
}

#########################################################
# 1) Check for strange Ensembl IDs
#########################################################
# if there is some row that doesn't contain an Ensembl ID
if(any(!grepl("ENST\\d{11}$", transcripts[,1]))) { 
  print(paste("Ignoring line", which(!grepl("ENST\\d{11}$", transcripts[,1])),
              "-", transcripts[which(!grepl("ENST\\d{11}$", transcripts[,1])),], "-",
              "from input file.", sep=" "))
  
  # Remove strange IDs from data.frame and get unique entries
  # BUT!! they are kept in input file
  transcripts<-as.character(unique(transcripts[-which(!grepl("ENST\\d{11}$", transcripts[,1])),]))
}

print(paste("Reading", length(transcripts), "transcripts.", sep=" "))

#########################################################
# 2) run function with corrected Ensembl IDs
#########################################################
umd<-UMDpredictor(transcripts)

#########################################################
# 3) write-table
#########################################################
print("Writing individual transcripts files...")
dir.create("./UMD_tmp/", showWarnings = TRUE, recursive = FALSE)
mclapply(names(umd), function(x){
  write.table(umd[[x]], paste("./UMD_tmp/", x,".txt",sep=""), col.names=F, row.names=F, quote=F, sep="\t")
}, mc.preschedule = TRUE, mc.cores = 8)

# add header to final file
write.table("#Chr\tPos\tRef\tAlt\tHGVS_c\tHGVS_p\tHGNC_symbol\tENSTranscript\tUMD_pred\tUMD_score", "./UMD_tmp/header.txt", col.names=F, row.names=F, quote=F, sep="\t")

print("Concatenate transcript files...")
system(paste("cat ./UMD_tmp/header.txt ./UMD_tmp/ENS*.txt > ", filename, ".txt",sep=""))

#########################################################
# 4) sort otuput file and indexed it
#########################################################
print("Sort and Index file.")
system(paste("less", paste(filename,".txt",sep="") , "|", "body sort -k1,1 -k2,2n", "-", ">", paste(filename, "_sort_header.txt", sep=""), sep=" "))
system(paste("mv", paste(filename, "_sort_header.txt", sep=""), paste(filename, ".txt", sep=""), sep=" "))
# index "_sort.txt"
system(paste("bgzip", paste(filename, ".txt", sep=""), sep=" "))
system(paste("tabix -b2 -e2", paste(filename, ".txt.gz", sep=""), sep=" "))

sink() # close log file
