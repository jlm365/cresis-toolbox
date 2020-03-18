% script convert_records_to_new_format_2010_Antarctica_DC8
%
% Convert from old records_YYYYMMDD_segS standard to 
% records_YYYYMMDD_SS standard

% =========================================================================
% User Settings
% =========================================================================
records_path = '/cresis/scratch1/mdce/csarp_support/records/mcords/2010_Antarctica_DC8';
old_records_path = '/cresis/scratch1/mdce/csarp_support/records/mcords/old_2010_Antarctica_DC8';
params = read_param_xls('/cresis/projects/dev/csarp_support/documents/mcords_param_2010_Antarctica_DC8.xls');

convert_records_to_new_format;
