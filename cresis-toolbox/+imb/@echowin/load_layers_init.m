function load_layers_init(obj)
% echowin.load_layers_init(obj)
%
% Initializes layer structures and layer plot handles

if strcmpi(obj.eg.layers.source,'OPS')
  %% OPS: Preallocating layer arrays
  for idx = 1:length(obj.eg.layers.lyr_id)
    obj.eg.layers.x{idx} = double(obj.eg.map_gps_time); % gps-time
    obj.eg.layers.y{idx} = NaN*zeros(size(obj.eg.map_id)); % twtt
    obj.eg.layers.qual{idx} = NaN*zeros(size(obj.eg.map_id)); % integer 1-3
    obj.eg.layers.type{idx} = NaN*zeros(size(obj.eg.map_id)); % this is either 1 (manual) or 2 (auto)
  end
  
  %% LayerData: Preallocating layer arrays
else
  for idx = 1:length(obj.eg.layers.lyr_id)
      obj.eg.layers.x{idx} = []; %gps time
      obj.eg.layers.y{idx} = []; % twtt
      obj.eg.layers.qual{idx} = []; % integer 1-3
      obj.eg.layers.type{idx} = []; % this is either 1 (manual) or 2 (auto)
  end
end

%% Plot layers
delete(obj.h_layer);
delete(obj.h_quality);

% -------------------------------------------------------------------------
% WARNING: DO NOT IMPLEMENT WITH SCATTER... TOO SLOW RENDERING
% -------------------------------------------------------------------------
layer_data_x = obj.eg.layers.x;
for idx = 1:length(layer_data_x)
  % Manual points (plot this way to handle empty XData or YData
  obj.h_layer(2*(idx-1)+1) = plot(obj.h_axes,NaN,NaN,'bx');
  % Auto and manual points
  obj.h_layer(2*(idx-1)+2) = plot(obj.h_axes, ...
    NaN,NaN,'b--');

  % Good manual points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+1) = plot(obj.h_axes,1,1,'gx');
  
  % Good auto points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+2) = plot(obj.h_axes,1,1,'g--');

  % Moderate manual points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+3) = plot(obj.h_axes,1,1,'yx');
  
  % Moderate auto points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+4) = plot(obj.h_axes,1,1,'y--');

  % Derived manual points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+5) = plot(obj.h_axes,1,1,'rx');
  
  % Derived auto points (plot this way to handle empty XData or YData
  obj.h_quality(6*(idx-1)+6) = plot(obj.h_axes,1,1,'r--');
end

end
